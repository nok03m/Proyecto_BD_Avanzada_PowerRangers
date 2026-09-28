-- =====================================================================
-- 07_Procedimientos_Almacenados.sql
-- 20 procedimientos. Requiere 01 (esquema), 03 (funciones) y 05 (triggers).
-- Reglas comunes: START TRANSACTION / COMMIT, EXIT HANDLER con ROLLBACK + RESIGNAL,
-- validación de entradas con SIGNAL SQLSTATE '45000'.
-- El stock NO se modifica aquí al vender ni al cancelar: lo hacen los triggers 2 y 3
-- (evita doble conteo). Solo sp_AjustarStock y sp_ProcesarDevolucion lo tocan, y solo
-- para operaciones que los triggers no cubren.
-- =====================================================================
USE ecommerce_db;

DELIMITER $$

-- ---------------------------------------------------------------------
-- 1. sp_RealizarNuevaVenta
-- Propósito: crea una venta Pendiente con sus líneas; bloquea productos con FOR UPDATE,
--            valida stock, congela precios y calcula total y envío.
-- Parámetros: p_id_cliente INT, p_id_sucursal INT (NULL = la del cliente),
--             p_items JSON  ->  [{"id_producto":1,"cantidad":2}, ...]
-- Retorna: OUT p_id_venta INT, OUT p_total DECIMAL(12,2)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_RealizarNuevaVenta$$
CREATE PROCEDURE sp_RealizarNuevaVenta(
  IN  p_id_cliente  INT,
  IN  p_id_sucursal INT,
  IN  p_items       JSON,
  OUT p_id_venta    INT,
  OUT p_total       DECIMAL(12,2))
BEGIN
  DECLARE v_fin        INT DEFAULT 0;
  DECLARE v_id_prod    INT;
  DECLARE v_cant       INT;
  DECLARE v_precio     DECIMAL(12,2);
  DECLARE v_invalidos  INT DEFAULT 0;
  DECLARE v_bloqueados INT DEFAULT 0;
  DECLARE v_sin_stock  INT DEFAULT 0;
  DECLARE v_sucursal   INT;
  DECLARE cur CURSOR FOR SELECT id_producto, cantidad FROM tmp_items_venta ORDER BY id_producto;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_id_venta = NULL, p_total = NULL;

  IF p_id_cliente IS NULL
     OR NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente AND activo = TRUE) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente o inactivo';
  END IF;
  IF p_items IS NULL OR JSON_TYPE(p_items) <> 'ARRAY' OR JSON_LENGTH(p_items) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La lista de productos debe ser un arreglo JSON no vacío';
  END IF;

  -- Agrupa productos repetidos y valida entradas antes de abrir la transacción
  DROP TEMPORARY TABLE IF EXISTS tmp_items_venta;
  CREATE TEMPORARY TABLE tmp_items_venta AS
    SELECT jt.id_producto, SUM(jt.cantidad) AS cantidad
      FROM JSON_TABLE(p_items, '$[*]' COLUMNS (
             id_producto INT PATH '$.id_producto',
             cantidad    INT PATH '$.cantidad')) jt
     GROUP BY jt.id_producto;

  SELECT COUNT(*) INTO v_invalidos
    FROM tmp_items_venta t
    LEFT JOIN productos p ON p.id_producto = t.id_producto
   WHERE t.id_producto IS NULL OR t.cantidad IS NULL OR t.cantidad <= 0
      OR p.id_producto IS NULL OR p.activo = FALSE;
  IF v_invalidos > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Hay productos inexistentes, inactivos o con cantidad inválida';
  END IF;

  START TRANSACTION;

  -- Bloquea las filas de productos involucradas y verifica stock con lectura actual
  SELECT COUNT(*) INTO v_bloqueados
    FROM productos p
    JOIN tmp_items_venta t ON t.id_producto = p.id_producto
     FOR UPDATE;
  SELECT COUNT(*) INTO v_sin_stock
    FROM productos p
    JOIN tmp_items_venta t ON t.id_producto = p.id_producto
   WHERE p.stock < t.cantidad
     FOR UPDATE;
  IF v_sin_stock > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock insuficiente para uno o más productos';
  END IF;

  SELECT COALESCE(p_id_sucursal, id_sucursal) INTO v_sucursal
    FROM clientes WHERE id_cliente = p_id_cliente;

  INSERT INTO ventas (id_cliente, id_sucursal, estado) VALUES (p_id_cliente, v_sucursal, 'Pendiente');
  SET p_id_venta = LAST_INSERT_ID();

  -- Inserta línea por línea: un INSERT ... SELECT FROM productos chocaría con el trigger 2
  -- (error 1442: no se puede actualizar productos mientras la sentencia lo lee).
  OPEN cur;
  lineas: LOOP
    FETCH cur INTO v_id_prod, v_cant;
    IF v_fin = 1 THEN LEAVE lineas; END IF;
    SELECT precio INTO v_precio FROM productos WHERE id_producto = v_id_prod;
    INSERT INTO detalle_ventas (id_venta, id_producto, cantidad, precio_unitario_congelado)
    VALUES (p_id_venta, v_id_prod, v_cant, v_precio);   -- trigger 2 descuenta stock, trigger 8 suma total
  END LOOP;
  CLOSE cur;

  UPDATE ventas
     SET costo_envio = fn_CostoEnvio(fn_PesoTotalVenta(p_id_venta))
   WHERE id_venta = p_id_venta;

  SELECT total INTO p_total FROM ventas WHERE id_venta = p_id_venta;
  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_items_venta;
END$$
-- Ejemplo:
-- CALL sp_RealizarNuevaVenta(1, NULL, '[{"id_producto":9,"cantidad":2},{"id_producto":10,"cantidad":1}]', @id, @total);
-- SELECT @id, @total;

-- ---------------------------------------------------------------------
-- 2. sp_ProcesarPago
-- Propósito: registra el pago aprobado de una venta Pendiente y la pasa a Pagado.
-- Parámetros: p_id_venta INT, p_metodo VARCHAR(20) ('Tarjeta','PSE','Efectivo','Transferencia'),
--             p_monto DECIMAL(12,2) (debe igualar total + costo_envio).
-- Retorna: OUT p_id_pago INT
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ProcesarPago$$
CREATE PROCEDURE sp_ProcesarPago(
  IN  p_id_venta INT,
  IN  p_metodo   VARCHAR(20),
  IN  p_monto    DECIMAL(12,2),
  OUT p_id_pago  INT)
BEGIN
  DECLARE v_estado VARCHAR(20) DEFAULT NULL;
  DECLARE v_total  DECIMAL(12,2);
  DECLARE v_envio  DECIMAL(12,2);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_id_pago = NULL;
  IF p_id_venta IS NULL OR p_monto IS NULL OR p_monto <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta o monto inválido';
  END IF;
  IF p_metodo NOT IN ('Tarjeta','PSE','Efectivo','Transferencia') OR p_metodo IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Método de pago no permitido';
  END IF;

  START TRANSACTION;
  SELECT estado, total, costo_envio INTO v_estado, v_total, v_envio
    FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
  IF v_estado IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no existe';
  END IF;
  IF v_estado <> 'Pendiente' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se pueden pagar ventas Pendientes';
  END IF;
  IF v_total <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no tiene líneas';
  END IF;
  IF p_monto <> v_total + v_envio THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El monto no coincide con total + envío';
  END IF;

  INSERT INTO pagos (id_venta, monto, metodo, estado, referencia)
  VALUES (p_id_venta, p_monto, p_metodo, 'Aprobado', CONCAT('PAY-', LPAD(p_id_venta, 6, '0')));
  SET p_id_pago = LAST_INSERT_ID();

  UPDATE ventas SET estado = 'Pagado' WHERE id_venta = p_id_venta;
  COMMIT;
END$$
-- Ejemplo: CALL sp_ProcesarPago(321, 'PSE', 3215000.00, @id_pago);

-- ---------------------------------------------------------------------
-- 3. sp_CancelarPedido
-- Propósito: cancela una venta Pendiente o Pagada (el trigger 3 restaura el stock).
-- Parámetros: p_id_venta INT, p_motivo VARCHAR(200).
-- Retorna: nada (error si no se puede cancelar).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_CancelarPedido$$
CREATE PROCEDURE sp_CancelarPedido(IN p_id_venta INT, IN p_motivo VARCHAR(200))
BEGIN
  DECLARE v_estado VARCHAR(20) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_id_venta IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta inválida';
  END IF;
  START TRANSACTION;
  SELECT estado INTO v_estado FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
  IF v_estado IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no existe';
  END IF;
  IF v_estado NOT IN ('Pendiente','Pagado') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se cancelan ventas Pendientes o Pagadas';
  END IF;
  UPDATE ventas SET estado = 'Cancelado' WHERE id_venta = p_id_venta;
  UPDATE pagos SET estado = 'Rechazado' WHERE id_venta = p_id_venta AND estado = 'Pendiente';
  INSERT INTO log_permisos (usuario, accion, detalle)
  VALUES (CURRENT_USER(), 'CANCELAR_PEDIDO', CONCAT('Venta ', p_id_venta, ': ', COALESCE(p_motivo, 'sin motivo')));
  COMMIT;
END$$
-- Ejemplo: CALL sp_CancelarPedido(321, 'Cliente desistió');

-- ---------------------------------------------------------------------
-- 4. sp_ActualizarEstadoPedido
-- Propósito: avanza el estado de un pedido; el trigger 13 valida la transición.
-- Parámetros: p_id_venta INT, p_nuevo_estado VARCHAR(20).
-- Retorna: nada.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ActualizarEstadoPedido$$
CREATE PROCEDURE sp_ActualizarEstadoPedido(IN p_id_venta INT, IN p_nuevo_estado VARCHAR(20))
BEGIN
  DECLARE v_id INT DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_id_venta IS NULL OR p_nuevo_estado IS NULL
     OR p_nuevo_estado NOT IN ('Pendiente','Pagado','Enviado','Entregado','Cancelado','Devuelto') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta o estado inválido';
  END IF;
  START TRANSACTION;
  SELECT id_venta INTO v_id FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
  IF v_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no existe';
  END IF;
  UPDATE ventas SET estado = p_nuevo_estado WHERE id_venta = p_id_venta;
  COMMIT;
END$$
-- Ejemplo: CALL sp_ActualizarEstadoPedido(321, 'Enviado');

-- ---------------------------------------------------------------------
-- 5. sp_ProcesarDevolucion
-- Propósito: registra una devolución aprobada de una venta Entregada, reintegra stock
--            y marca la venta como Devuelto si ya se devolvió todo.
-- Parámetros: p_id_venta INT, p_id_producto INT, p_cantidad INT, p_motivo VARCHAR(200).
-- Retorna: OUT p_id_devolucion INT
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ProcesarDevolucion$$
CREATE PROCEDURE sp_ProcesarDevolucion(
  IN  p_id_venta      INT,
  IN  p_id_producto   INT,
  IN  p_cantidad      INT,
  IN  p_motivo        VARCHAR(200),
  OUT p_id_devolucion INT)
BEGIN
  DECLARE v_estado    VARCHAR(20) DEFAULT NULL;
  DECLARE v_comprada  INT DEFAULT NULL;
  DECLARE v_devuelta  INT DEFAULT 0;
  DECLARE v_pendiente INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_id_devolucion = NULL;
  IF p_id_venta IS NULL OR p_id_producto IS NULL OR p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Parámetros de devolución inválidos';
  END IF;

  START TRANSACTION;
  SELECT estado INTO v_estado FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
  IF v_estado IS NULL OR v_estado <> 'Entregado' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se devuelven ventas en estado Entregado';
  END IF;
  SELECT cantidad INTO v_comprada FROM detalle_ventas
   WHERE id_venta = p_id_venta AND id_producto = p_id_producto;
  IF v_comprada IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no pertenece a la venta';
  END IF;
  SELECT COALESCE(SUM(cantidad), 0) INTO v_devuelta FROM devoluciones
   WHERE id_venta = p_id_venta AND id_producto = p_id_producto AND estado = 'Aprobada';
  IF p_cantidad > v_comprada - v_devuelta THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad supera lo comprado pendiente de devolver';
  END IF;

  INSERT INTO devoluciones (id_venta, id_producto, cantidad, motivo, estado)
  VALUES (p_id_venta, p_id_producto, p_cantidad, p_motivo, 'Aprobada');
  SET p_id_devolucion = LAST_INSERT_ID();

  UPDATE productos SET stock = stock + p_cantidad WHERE id_producto = p_id_producto;
  INSERT INTO ajustes_stock (id_producto, cantidad_ajuste, motivo, usuario)
  VALUES (p_id_producto, p_cantidad, CONCAT('Devolución venta ', p_id_venta), CURRENT_USER());

  -- Si todas las líneas quedaron devueltas por completo, la venta pasa a Devuelto
  SELECT COUNT(*) INTO v_pendiente
    FROM detalle_ventas d
    LEFT JOIN (SELECT id_producto, SUM(cantidad) AS devuelto
                 FROM devoluciones
                WHERE id_venta = p_id_venta AND estado = 'Aprobada'
                GROUP BY id_producto) r ON r.id_producto = d.id_producto
   WHERE d.id_venta = p_id_venta AND d.cantidad > COALESCE(r.devuelto, 0);
  IF v_pendiente = 0 THEN
    UPDATE ventas SET estado = 'Devuelto' WHERE id_venta = p_id_venta;
  END IF;
  COMMIT;
END$$
-- Ejemplo: CALL sp_ProcesarDevolucion(1, 5, 1, 'Producto defectuoso', @id_dev);

-- ---------------------------------------------------------------------
-- 6. sp_AjustarStock
-- Propósito: ajuste manual de inventario (positivo o negativo) con registro en ajustes_stock.
-- Parámetros: p_id_producto INT, p_cantidad INT (<> 0), p_motivo VARCHAR(200).
-- Retorna: nada. El trigger 1 impide dejar stock negativo.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_AjustarStock$$
CREATE PROCEDURE sp_AjustarStock(IN p_id_producto INT, IN p_cantidad INT, IN p_motivo VARCHAR(200))
BEGIN
  DECLARE v_stock INT DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_id_producto IS NULL OR p_cantidad IS NULL OR p_cantidad = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto o cantidad inválida';
  END IF;
  START TRANSACTION;
  SELECT stock INTO v_stock FROM productos WHERE id_producto = p_id_producto FOR UPDATE;
  IF v_stock IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
  END IF;
  UPDATE productos SET stock = stock + p_cantidad WHERE id_producto = p_id_producto;
  INSERT INTO ajustes_stock (id_producto, cantidad_ajuste, motivo, usuario)
  VALUES (p_id_producto, p_cantidad, p_motivo, CURRENT_USER());
  COMMIT;
END$$
-- Ejemplo: CALL sp_AjustarStock(5, 10, 'Reposición recibida');

-- ---------------------------------------------------------------------
-- 7. sp_ActualizarPrecioProducto
-- Propósito: cambia el precio de un producto (triggers 4 y 5 registran y limitan el cambio).
-- Parámetros: p_id_producto INT, p_precio_nuevo DECIMAL(12,2) (> 0).
-- Retorna: nada.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ActualizarPrecioProducto$$
CREATE PROCEDURE sp_ActualizarPrecioProducto(IN p_id_producto INT, IN p_precio_nuevo DECIMAL(12,2))
BEGIN
  DECLARE v_id INT DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_id_producto IS NULL OR p_precio_nuevo IS NULL OR p_precio_nuevo <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto o precio inválido';
  END IF;
  START TRANSACTION;
  SELECT id_producto INTO v_id FROM productos WHERE id_producto = p_id_producto FOR UPDATE;
  IF v_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
  END IF;
  UPDATE productos SET precio = p_precio_nuevo WHERE id_producto = p_id_producto;
  COMMIT;
END$$
-- Ejemplo: CALL sp_ActualizarPrecioProducto(3, 1550000);

-- ---------------------------------------------------------------------
-- 8. sp_AplicarDescuentoCategoria
-- Propósito: baja el precio de todos los productos de una categoría y sus subcategorías.
-- Parámetros: p_id_categoria INT, p_porcentaje DECIMAL(5,2) (0 < x <= 50).
-- Retorna: OUT p_filas INT (productos modificados).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_AplicarDescuentoCategoria$$
CREATE PROCEDURE sp_AplicarDescuentoCategoria(
  IN  p_id_categoria INT,
  IN  p_porcentaje   DECIMAL(5,2),
  OUT p_filas        INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_filas = 0;
  IF p_id_categoria IS NULL OR p_porcentaje IS NULL OR p_porcentaje <= 0 OR p_porcentaje > 50 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Categoría inválida o porcentaje fuera de (0, 50]';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM categorias WHERE id_categoria = p_id_categoria) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La categoría no existe';
  END IF;
  START TRANSACTION;
  UPDATE productos
     SET precio = fn_PrecioConDescuento(precio, p_porcentaje)
   WHERE id_categoria IN (
     WITH RECURSIVE arbol AS (
       SELECT id_categoria FROM categorias WHERE id_categoria = p_id_categoria
       UNION ALL
       SELECT c.id_categoria FROM categorias c JOIN arbol a ON c.id_categoria_padre = a.id_categoria
     ) SELECT id_categoria FROM arbol);
  SET p_filas = ROW_COUNT();
  COMMIT;
END$$
-- Ejemplo: CALL sp_AplicarDescuentoCategoria(9, 10, @n); SELECT @n;

-- ---------------------------------------------------------------------
-- 9. sp_RegistrarCliente
-- Propósito: alta de cliente. Recibe el HASH de la contraseña (SHA-256 en hex, 64 caracteres);
--            jamás se almacena ni se recibe la contraseña en claro.
-- Parámetros: p_nombre, p_email, p_password_hash CHAR(64), p_direccion, p_fecha_nacimiento,
--             p_ciudad, p_region, p_id_sucursal, p_referido_por.
-- Retorna: OUT p_id_cliente INT
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_RegistrarCliente$$
CREATE PROCEDURE sp_RegistrarCliente(
  IN  p_nombre           VARCHAR(100),
  IN  p_email            VARCHAR(120),
  IN  p_password_hash    CHAR(64),
  IN  p_direccion        VARCHAR(200),
  IN  p_fecha_nacimiento DATE,
  IN  p_ciudad           VARCHAR(60),
  IN  p_region           VARCHAR(60),
  IN  p_id_sucursal      INT,
  IN  p_referido_por     INT,
  OUT p_id_cliente       INT)
BEGIN
  DECLARE EXIT HANDLER FOR 1062
  BEGIN
    ROLLBACK;
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El correo ya está registrado';
  END;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_id_cliente = NULL;
  IF p_nombre IS NULL OR TRIM(p_nombre) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nombre es obligatorio';
  END IF;
  IF fn_ValidarEmail(p_email) IS NULL OR fn_ValidarEmail(p_email) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Correo electrónico inválido';
  END IF;
  IF p_password_hash IS NULL OR p_password_hash NOT REGEXP '^[0-9a-fA-F]{64}$' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Se requiere un hash SHA-256 de 64 caracteres hexadecimales';
  END IF;
  IF p_fecha_nacimiento IS NOT NULL AND p_fecha_nacimiento > CURDATE() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Fecha de nacimiento futura';
  END IF;

  START TRANSACTION;
  INSERT INTO clientes (nombre, email, password_hash, direccion, fecha_nacimiento,
                        ciudad, region, id_sucursal, referido_por)
  VALUES (TRIM(p_nombre), p_email, LOWER(p_password_hash), p_direccion, p_fecha_nacimiento,
          p_ciudad, p_region, p_id_sucursal, p_referido_por);
  SET p_id_cliente = LAST_INSERT_ID();
  COMMIT;
END$$
-- Ejemplo: CALL sp_RegistrarCliente('Nora Ruiz','nora@correo.com',SHA2('Clave#Nueva1',256),
--          'Calle 1 # 2-3','1990-05-10','Cúcuta','Norte de Santander',1,NULL,@id);

-- ---------------------------------------------------------------------
-- 10. sp_DesactivarCliente
-- Propósito: baja lógica de un cliente y cierre de sus carritos activos.
-- Parámetros: p_id_cliente INT. Retorna: nada.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_DesactivarCliente$$
CREATE PROCEDURE sp_DesactivarCliente(IN p_id_cliente INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_id_cliente IS NULL OR NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente no existe';
  END IF;
  START TRANSACTION;
  UPDATE clientes SET activo = FALSE WHERE id_cliente = p_id_cliente;
  UPDATE carritos SET estado = 'Abandonado' WHERE id_cliente = p_id_cliente AND estado = 'Activo';
  COMMIT;
END$$
-- Ejemplo: CALL sp_DesactivarCliente(55);

-- ---------------------------------------------------------------------
-- 11. sp_ObtenerHistorialCliente
-- Propósito: devuelve el perfil básico (sin email, hash ni dirección) y el historial de compras.
-- Parámetros: p_id_cliente INT. Retorna: 2 conjuntos de resultados.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ObtenerHistorialCliente$$
CREATE PROCEDURE sp_ObtenerHistorialCliente(IN p_id_cliente INT)
BEGIN
  IF p_id_cliente IS NULL OR NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente no existe';
  END IF;
  SELECT id_cliente, nombre, ciudad, region, total_gastado, fecha_ultimo_pedido, activo,
         fn_NivelCliente(id_cliente) AS nivel
    FROM clientes WHERE id_cliente = p_id_cliente;
  SELECT v.id_venta, v.fecha_venta, v.estado, v.total, v.costo_envio,
         COUNT(d.id_detalle) AS lineas, COALESCE(SUM(d.cantidad), 0) AS unidades
    FROM ventas v
    LEFT JOIN detalle_ventas d ON d.id_venta = v.id_venta
   WHERE v.id_cliente = p_id_cliente
   GROUP BY v.id_venta, v.fecha_venta, v.estado, v.total, v.costo_envio
   ORDER BY v.fecha_venta DESC;
END$$
-- Ejemplo: CALL sp_ObtenerHistorialCliente(1);

-- ---------------------------------------------------------------------
-- 12. sp_ReporteVentasPorPeriodo
-- Propósito: ventas diarias entre dos fechas (sin canceladas).
-- Parámetros: p_desde DATE, p_hasta DATE (p_desde <= p_hasta). Retorna: 1 conjunto de resultados.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ReporteVentasPorPeriodo$$
CREATE PROCEDURE sp_ReporteVentasPorPeriodo(IN p_desde DATE, IN p_hasta DATE)
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rango de fechas inválido';
  END IF;
  SELECT DATE(fecha_venta) AS dia, COUNT(*) AS ventas,
         ROUND(SUM(total), 2) AS ingresos, ROUND(AVG(total), 2) AS ticket_promedio
    FROM ventas
   WHERE estado <> 'Cancelado'
     AND fecha_venta >= p_desde AND fecha_venta < DATE_ADD(p_hasta, INTERVAL 1 DAY)
   GROUP BY DATE(fecha_venta)
   ORDER BY dia;
END$$
-- Ejemplo: CALL sp_ReporteVentasPorPeriodo('2026-08-01', '2026-08-31');

-- ---------------------------------------------------------------------
-- 13. sp_TopClientes
-- Propósito: clientes con mayor gasto en un periodo (sin canceladas).
-- Parámetros: p_limite INT (1-100), p_desde DATE, p_hasta DATE. Retorna: 1 conjunto de resultados.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_TopClientes$$
CREATE PROCEDURE sp_TopClientes(IN p_limite INT, IN p_desde DATE, IN p_hasta DATE)
BEGIN
  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 100
     OR p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Límite o rango de fechas inválido';
  END IF;
  SELECT c.id_cliente, c.nombre, c.ciudad, COUNT(*) AS compras, ROUND(SUM(v.total), 2) AS gasto
    FROM ventas v
    JOIN clientes c ON c.id_cliente = v.id_cliente
   WHERE v.estado <> 'Cancelado'
     AND v.fecha_venta >= p_desde AND v.fecha_venta < DATE_ADD(p_hasta, INTERVAL 1 DAY)
   GROUP BY c.id_cliente, c.nombre, c.ciudad
   ORDER BY gasto DESC
   LIMIT p_limite;
END$$
-- Ejemplo: CALL sp_TopClientes(10, '2025-01-01', '2026-12-31');

-- ---------------------------------------------------------------------
-- 14. sp_ActualizarRankingProductos
-- Propósito: reconstruye ranking_productos (vista materializada simulada).
-- Parámetros: ninguno. Retorna: nada.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ActualizarRankingProductos$$
CREATE PROCEDURE sp_ActualizarRankingProductos()
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  DELETE FROM ranking_productos;
  INSERT INTO ranking_productos (id_producto, unidades, ingresos, posicion)
  SELECT t.id_producto, t.unidades, t.ingresos,
         RANK() OVER (ORDER BY t.ingresos DESC)
    FROM (SELECT d.id_producto, SUM(d.cantidad) AS unidades,
                 SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
            FROM detalle_ventas d
            JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
           GROUP BY d.id_producto) t;
  COMMIT;
END$$
-- Ejemplo: CALL sp_ActualizarRankingProductos();

-- ---------------------------------------------------------------------
-- 15. sp_GenerarReporteReabastecimiento
-- Propósito: lista los productos con stock <= mínimo y la cantidad sugerida
--            (hasta 3 veces el mínimo). Reemplaza el reporte del día.
-- Parámetros: ninguno. Retorna: nada.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_GenerarReporteReabastecimiento$$
CREATE PROCEDURE sp_GenerarReporteReabastecimiento()
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  DELETE FROM reporte_reabastecimiento WHERE DATE(fecha) = CURRENT_DATE;
  INSERT INTO reporte_reabastecimiento (id_producto, stock_actual, stock_minimo, cantidad_sugerida)
  SELECT id_producto, stock, stock_minimo, GREATEST(stock_minimo * 3 - stock, 1)
    FROM productos
   WHERE activo = TRUE AND stock <= stock_minimo;
  COMMIT;
END$$
-- Ejemplo: CALL sp_GenerarReporteReabastecimiento();

-- ---------------------------------------------------------------------
-- 16. sp_GenerarReporteProveedores
-- Propósito: registra por proveedor el número de productos activos y el valor del inventario a costo.
-- Parámetros: ninguno. Retorna: nada.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_GenerarReporteProveedores$$
CREATE PROCEDURE sp_GenerarReporteProveedores()
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;
  DELETE FROM reporte_proveedores WHERE DATE(fecha) = CURRENT_DATE;
  INSERT INTO reporte_proveedores (id_proveedor, num_productos, valor_inventario)
  SELECT pv.id_proveedor, COUNT(p.id_producto), COALESCE(SUM(p.stock * p.costo), 0)
    FROM proveedores pv
    LEFT JOIN productos p ON p.id_proveedor = pv.id_proveedor AND p.activo = TRUE
   WHERE pv.activo = TRUE
   GROUP BY pv.id_proveedor;
  COMMIT;
END$$
-- Ejemplo: CALL sp_GenerarReporteProveedores();

-- ---------------------------------------------------------------------
-- 17. sp_CalcularKPIsMensuales
-- Propósito: calcula ingresos, ventas, ticket promedio, clientes nuevos (primera compra
--            en el mes) y tasa de cancelación de un mes. Idempotente (REPLACE).
-- Parámetros: p_anio SMALLINT, p_mes TINYINT (1-12). Retorna: nada.
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_CalcularKPIsMensuales$$
CREATE PROCEDURE sp_CalcularKPIsMensuales(IN p_anio SMALLINT, IN p_mes TINYINT)
BEGIN
  DECLARE v_ini DATE;
  DECLARE v_fin DATE;
  DECLARE v_ingresos DECIMAL(14,2);
  DECLARE v_ventas INT;
  DECLARE v_nuevos INT;
  DECLARE v_total_mes INT;
  DECLARE v_canceladas INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_anio IS NULL OR p_mes IS NULL OR p_mes < 1 OR p_mes > 12 OR p_anio < 2000 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Año o mes inválido';
  END IF;
  SET v_ini = STR_TO_DATE(CONCAT(p_anio, '-', LPAD(p_mes, 2, '0'), '-01'), '%Y-%m-%d');
  SET v_fin = DATE_ADD(v_ini, INTERVAL 1 MONTH);

  SELECT COALESCE(SUM(total), 0), COUNT(*) INTO v_ingresos, v_ventas
    FROM ventas
   WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin;

  SELECT COUNT(*), COALESCE(SUM(estado = 'Cancelado'), 0) INTO v_total_mes, v_canceladas
    FROM ventas WHERE fecha_venta >= v_ini AND fecha_venta < v_fin;

  SELECT COUNT(*) INTO v_nuevos
    FROM (SELECT id_cliente, MIN(fecha_venta) AS primera
            FROM ventas WHERE estado <> 'Cancelado'
           GROUP BY id_cliente) f
   WHERE f.primera >= v_ini AND f.primera < v_fin;

  START TRANSACTION;
  REPLACE INTO kpis_mensuales (anio_mes, ingresos, num_ventas, ticket_promedio, clientes_nuevos, tasa_cancelacion)
  VALUES (DATE_FORMAT(v_ini, '%Y-%m'), v_ingresos, v_ventas,
          IF(v_ventas = 0, 0, ROUND(v_ingresos / v_ventas, 2)), v_nuevos,
          IF(v_total_mes = 0, 0, ROUND(100 * v_canceladas / v_total_mes, 2)));
  COMMIT;
END$$
-- Ejemplo: CALL sp_CalcularKPIsMensuales(2026, 8);

-- ---------------------------------------------------------------------
-- 18. sp_CrearPromocion
-- Propósito: crea una promoción validando código, tipo, valor y fechas.
-- Parámetros: p_codigo, p_descripcion, p_tipo ('Porcentaje'|'Monto'), p_valor, p_inicio, p_fin,
--             p_id_categoria (NULL = global). Retorna: OUT p_id_promocion INT
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_CrearPromocion$$
CREATE PROCEDURE sp_CrearPromocion(
  IN  p_codigo        VARCHAR(30),
  IN  p_descripcion   VARCHAR(200),
  IN  p_tipo          VARCHAR(20),
  IN  p_valor         DECIMAL(12,2),
  IN  p_inicio        DATE,
  IN  p_fin           DATE,
  IN  p_id_categoria  INT,
  OUT p_id_promocion  INT)
BEGIN
  DECLARE EXIT HANDLER FOR 1062
  BEGIN
    ROLLBACK;
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El código de promoción ya existe';
  END;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_id_promocion = NULL;
  IF p_codigo IS NULL OR TRIM(p_codigo) = '' OR p_tipo IS NULL OR p_tipo NOT IN ('Porcentaje','Monto')
     OR p_valor IS NULL OR p_valor <= 0 OR (p_tipo = 'Porcentaje' AND p_valor > 100)
     OR p_inicio IS NULL OR p_fin IS NULL OR p_fin < p_inicio THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Datos de promoción inválidos';
  END IF;
  IF p_id_categoria IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM categorias WHERE id_categoria = p_id_categoria) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La categoría no existe';
  END IF;

  START TRANSACTION;
  INSERT INTO promociones (codigo, descripcion, tipo, valor, fecha_inicio, fecha_fin, id_categoria, activa)
  VALUES (UPPER(TRIM(p_codigo)), p_descripcion, p_tipo, p_valor, p_inicio, p_fin, p_id_categoria,
          (CURDATE() BETWEEN p_inicio AND p_fin));
  SET p_id_promocion = LAST_INSERT_ID();
  COMMIT;
END$$
-- Ejemplo: CALL sp_CrearPromocion('NAVIDAD25','25% en juguetes','Porcentaje',25,'2026-12-01','2026-12-24',10,@id);

-- ---------------------------------------------------------------------
-- 19. sp_AgregarResena
-- Propósito: registra una reseña (el trigger 20 exige una compra entregada).
-- Parámetros: p_id_producto INT, p_id_cliente INT, p_calificacion TINYINT (1-5), p_comentario VARCHAR(500).
-- Retorna: OUT p_id_resena INT
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_AgregarResena$$
CREATE PROCEDURE sp_AgregarResena(
  IN  p_id_producto  INT,
  IN  p_id_cliente   INT,
  IN  p_calificacion TINYINT,
  IN  p_comentario   VARCHAR(500),
  OUT p_id_resena    INT)
BEGIN
  DECLARE EXIT HANDLER FOR 1062
  BEGIN
    ROLLBACK;
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente ya reseñó este producto';
  END;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_id_resena = NULL;
  IF p_id_producto IS NULL OR p_id_cliente IS NULL
     OR p_calificacion IS NULL OR p_calificacion NOT BETWEEN 1 AND 5 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto, cliente o calificación inválidos';
  END IF;
  START TRANSACTION;
  INSERT INTO resenas_producto (id_producto, id_cliente, calificacion, comentario)
  VALUES (p_id_producto, p_id_cliente, p_calificacion, p_comentario);
  SET p_id_resena = LAST_INSERT_ID();
  COMMIT;
END$$
-- Ejemplo: CALL sp_AgregarResena(1, 1, 5, 'Excelente producto', @id);

-- ---------------------------------------------------------------------
-- 20. sp_ArchivarVentasAntiguas
-- Propósito: copia a ventas_archivo las ventas cerradas (Entregado, Devuelto, Cancelado)
--            anteriores a N meses. No borra el origen; es idempotente (INSERT IGNORE).
-- Parámetros: p_meses INT (>= 1). Retorna: OUT p_filas INT (filas nuevas copiadas).
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ArchivarVentasAntiguas$$
CREATE PROCEDURE sp_ArchivarVentasAntiguas(IN p_meses INT, OUT p_filas INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET p_filas = 0;
  IF p_meses IS NULL OR p_meses < 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El número de meses debe ser al menos 1';
  END IF;
  START TRANSACTION;
  INSERT IGNORE INTO ventas_archivo (id_venta, id_cliente, id_sucursal, fecha_venta, estado, total, costo_envio)
  SELECT id_venta, id_cliente, id_sucursal, fecha_venta, estado, total, costo_envio
    FROM ventas
   WHERE fecha_venta < DATE_SUB(CURRENT_DATE, INTERVAL p_meses MONTH)
     AND estado IN ('Entregado','Devuelto','Cancelado');
  SET p_filas = ROW_COUNT();
  COMMIT;
END$$
-- Ejemplo: CALL sp_ArchivarVentasAntiguas(12, @n); SELECT @n;

DELIMITER ;
