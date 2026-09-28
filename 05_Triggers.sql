-- =====================================================================
-- 05_Triggers.sql
-- 20 triggers. Requiere 01 (esquema) y 03 (fn_CalcularTotalVenta, fn_ValidarEmail).
--
-- CÓMO SE EVITAN RECURSIÓN Y DOBLE CONTEO
--  * El stock SOLO lo modifican: trigger 2 (descuenta al insertar una línea),
--    trigger 3 (restaura al cancelar) y los procedimientos de ajuste/devolución.
--    sp_RealizarNuevaVenta NO toca el stock: inserta líneas y el trigger 2 descuenta.
--  * Las líneas de venta son inmutables (triggers 9 y 10): no hay UPDATE/DELETE de
--    líneas, así que el stock y el total nunca quedan desfasados por ediciones.
--  * ventas.total lo recalcula el trigger 8 (AFTER INSERT en detalle_ventas) con un
--    UPDATE sobre ventas; ese UPDATE dispara el trigger 11, que ajusta clientes.total_gastado
--    por la DIFERENCIA de total. Ningún trigger de ventas actualiza ventas (sin recursión).
--  * Los triggers de productos (1, 4, 5, 19) solo escriben en otras tablas (logs/alertas).
--  * Un trigger no puede modificar la tabla que dispara la sentencia (error 1442),
--    por eso los procedimientos insertan líneas una por una (no INSERT ... SELECT FROM productos).
--  * LIMITACIÓN: las ventas de la semilla (01) son históricas y su stock ya es neto; cancelar
--    una de ellas restauraría unidades que nunca se descontaron. Aplica solo a datos semilla.
-- =====================================================================
USE ecommerce_db;

-- Tabla de auditoría de precios (asignada a este archivo)
DROP TABLE IF EXISTS log_cambios_precio;
CREATE TABLE log_cambios_precio (
  id_log          INT AUTO_INCREMENT PRIMARY KEY,
  id_producto     INT NOT NULL,
  precio_anterior DECIMAL(12,2) NOT NULL,
  precio_nuevo    DECIMAL(12,2) NOT NULL,
  usuario         VARCHAR(80) NULL,
  fecha           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_lcp_prod FOREIGN KEY (id_producto)
    REFERENCES productos(id_producto) ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX idx_lcp_prod (id_producto),
  INDEX idx_lcp_fecha (fecha)
) ENGINE=InnoDB;

DELIMITER $$

-- 1. trg_prevent_negative_stock | BEFORE UPDATE ON productos
-- Bloquea cualquier actualización que deje el stock negativo (mensaje claro antes del CHECK).
DROP TRIGGER IF EXISTS trg_prevent_negative_stock$$
CREATE TRIGGER trg_prevent_negative_stock
BEFORE UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.stock < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock insuficiente: la operación dejaría el stock en negativo';
  END IF;
END$$

-- 2. trg_descontar_stock_venta | AFTER INSERT ON detalle_ventas
-- Descuenta del stock la cantidad vendida. Único punto de descuento (sin doble conteo).
DROP TRIGGER IF EXISTS trg_descontar_stock_venta$$
CREATE TRIGGER trg_descontar_stock_venta
AFTER INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  UPDATE productos SET stock = stock - NEW.cantidad WHERE id_producto = NEW.id_producto;
END$$

-- 3. trg_restaurar_stock_venta_cancelada | AFTER UPDATE ON ventas
-- Al pasar una venta a 'Cancelado' devuelve al stock las unidades de sus líneas (una sola vez:
-- el trigger 13 impide salir de 'Cancelado').
DROP TRIGGER IF EXISTS trg_restaurar_stock_venta_cancelada$$
CREATE TRIGGER trg_restaurar_stock_venta_cancelada
AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
  IF NEW.estado = 'Cancelado' AND OLD.estado <> 'Cancelado' THEN
    UPDATE productos p
      JOIN detalle_ventas d ON d.id_producto = p.id_producto
       SET p.stock = p.stock + d.cantidad
     WHERE d.id_venta = NEW.id_venta;
  END IF;
END$$

-- 4. trg_log_cambio_precio | AFTER UPDATE ON productos
-- Registra en log_cambios_precio todo cambio de precio.
DROP TRIGGER IF EXISTS trg_log_cambio_precio$$
CREATE TRIGGER trg_log_cambio_precio
AFTER UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.precio <> OLD.precio THEN
    INSERT INTO log_cambios_precio (id_producto, precio_anterior, precio_nuevo, usuario)
    VALUES (NEW.id_producto, OLD.precio, NEW.precio, CURRENT_USER());
  END IF;
END$$

-- 5. trg_limitar_cambio_precio | BEFORE UPDATE ON productos
-- Evita errores de digitación: un solo cambio no puede subir más de 2x ni bajar de 30% del precio.
DROP TRIGGER IF EXISTS trg_limitar_cambio_precio$$
CREATE TRIGGER trg_limitar_cambio_precio
BEFORE UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.precio <> OLD.precio
     AND (NEW.precio > OLD.precio * 2 OR NEW.precio < OLD.precio * 0.3) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cambio de precio fuera de rango permitido (entre 30% y 200% del precio actual)';
  END IF;
END$$

-- 6. trg_congelar_precio_detalle | BEFORE INSERT ON detalle_ventas
-- Si la línea llega sin precio (NULL o 0) congela el precio vigente del producto.
-- Nota: para omitir el precio se debe pasar 0 (la columna es NOT NULL).
DROP TRIGGER IF EXISTS trg_congelar_precio_detalle$$
CREATE TRIGGER trg_congelar_precio_detalle
BEFORE INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  IF NEW.precio_unitario_congelado IS NULL OR NEW.precio_unitario_congelado <= 0 THEN
    SET NEW.precio_unitario_congelado = (SELECT precio FROM productos WHERE id_producto = NEW.id_producto);
  END IF;
END$$

-- 7. trg_validar_detalle_venta | BEFORE INSERT ON detalle_ventas
-- Solo se agregan líneas a ventas Pendientes y con productos activos.
DROP TRIGGER IF EXISTS trg_validar_detalle_venta$$
CREATE TRIGGER trg_validar_detalle_venta
BEFORE INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  DECLARE v_estado VARCHAR(20);
  DECLARE v_activo BOOLEAN;
  SELECT estado INTO v_estado FROM ventas WHERE id_venta = NEW.id_venta;
  IF v_estado IS NULL OR v_estado <> 'Pendiente' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se pueden agregar líneas a ventas en estado Pendiente';
  END IF;
  SELECT activo INTO v_activo FROM productos WHERE id_producto = NEW.id_producto;
  IF v_activo IS NULL OR v_activo = FALSE THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe o está inactivo';
  END IF;
END$$

-- 8. trg_actualizar_total_venta | AFTER INSERT ON detalle_ventas
-- Recalcula ventas.total con fn_CalcularTotalVenta (total = suma de líneas).
DROP TRIGGER IF EXISTS trg_actualizar_total_venta$$
CREATE TRIGGER trg_actualizar_total_venta
AFTER INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  UPDATE ventas SET total = fn_CalcularTotalVenta(NEW.id_venta) WHERE id_venta = NEW.id_venta;
END$$

-- 9. trg_prevent_update_detalle | BEFORE UPDATE ON detalle_ventas
-- Las líneas son inmutables: garantiza total y stock consistentes.
DROP TRIGGER IF EXISTS trg_prevent_update_detalle$$
CREATE TRIGGER trg_prevent_update_detalle
BEFORE UPDATE ON detalle_ventas FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las líneas de venta no se pueden modificar; cancele la venta y cree una nueva';
END$$

-- 10. trg_prevent_delete_detalle | BEFORE DELETE ON detalle_ventas
-- Bloquea el borrado directo de líneas (el borrado en cascada desde ventas no dispara triggers).
DROP TRIGGER IF EXISTS trg_prevent_delete_detalle$$
CREATE TRIGGER trg_prevent_delete_detalle
BEFORE DELETE ON detalle_ventas FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las líneas de venta no se pueden eliminar; cancele la venta';
END$$

-- 11. trg_actualizar_total_gastado_cliente | AFTER UPDATE ON ventas
-- Mantiene clientes.total_gastado (ventas no canceladas) aplicando solo la diferencia.
DROP TRIGGER IF EXISTS trg_actualizar_total_gastado_cliente$$
CREATE TRIGGER trg_actualizar_total_gastado_cliente
AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
  IF NEW.estado = 'Cancelado' AND OLD.estado <> 'Cancelado' THEN
    UPDATE clientes SET total_gastado = GREATEST(total_gastado - OLD.total, 0)
     WHERE id_cliente = NEW.id_cliente;
  ELSEIF NEW.estado <> 'Cancelado' AND NEW.total <> OLD.total THEN
    UPDATE clientes SET total_gastado = GREATEST(total_gastado + (NEW.total - OLD.total), 0)
     WHERE id_cliente = NEW.id_cliente;
  END IF;
END$$

-- 12. trg_log_estado_pedido | AFTER UPDATE ON ventas
-- Historial de cambios de estado de cada pedido.
DROP TRIGGER IF EXISTS trg_log_estado_pedido$$
CREATE TRIGGER trg_log_estado_pedido
AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
  IF NEW.estado <> OLD.estado THEN
    INSERT INTO log_estado_pedido (id_venta, estado_anterior, estado_nuevo, usuario)
    VALUES (NEW.id_venta, OLD.estado, NEW.estado, CURRENT_USER());
  END IF;
END$$

-- 13. trg_validar_transicion_estado | BEFORE UPDATE ON ventas
-- Flujo permitido: Pendiente -> Pagado|Cancelado; Pagado -> Enviado|Cancelado;
-- Enviado -> Entregado; Entregado -> Devuelto. Cancelado y Devuelto son finales.
DROP TRIGGER IF EXISTS trg_validar_transicion_estado$$
CREATE TRIGGER trg_validar_transicion_estado
BEFORE UPDATE ON ventas FOR EACH ROW
BEGIN
  IF NEW.estado <> OLD.estado THEN
    IF NOT (   (OLD.estado = 'Pendiente' AND NEW.estado IN ('Pagado','Cancelado'))
            OR (OLD.estado = 'Pagado'    AND NEW.estado IN ('Enviado','Cancelado'))
            OR (OLD.estado = 'Enviado'   AND NEW.estado = 'Entregado')
            OR (OLD.estado = 'Entregado' AND NEW.estado = 'Devuelto')) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transición de estado no permitida para la venta';
    END IF;
  END IF;
END$$

-- 14. trg_actualizar_ultimo_pedido | AFTER INSERT ON ventas
-- Actualiza la fecha del último pedido del cliente.
DROP TRIGGER IF EXISTS trg_actualizar_ultimo_pedido$$
CREATE TRIGGER trg_actualizar_ultimo_pedido
AFTER INSERT ON ventas FOR EACH ROW
BEGIN
  UPDATE clientes SET fecha_ultimo_pedido = NEW.fecha_venta WHERE id_cliente = NEW.id_cliente;
END$$

-- 15. trg_log_clientes_insert | AFTER INSERT ON clientes
-- Auditoría de altas (nunca se registra el hash de la contraseña).
DROP TRIGGER IF EXISTS trg_log_clientes_insert$$
CREATE TRIGGER trg_log_clientes_insert
AFTER INSERT ON clientes FOR EACH ROW
BEGIN
  INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
  VALUES (NEW.id_cliente, 'INSERT', CONCAT('Alta: ', NEW.nombre, ' <', NEW.email, '>'), CURRENT_USER());
END$$

-- 16. trg_log_clientes_update | AFTER UPDATE ON clientes
-- Auditoría de cambios en datos de perfil (ignora cambios automáticos de total_gastado/último pedido).
DROP TRIGGER IF EXISTS trg_log_clientes_update$$
CREATE TRIGGER trg_log_clientes_update
AFTER UPDATE ON clientes FOR EACH ROW
BEGIN
  IF NOT (OLD.nombre <=> NEW.nombre) OR NOT (OLD.email <=> NEW.email)
     OR NOT (OLD.ciudad <=> NEW.ciudad) OR NOT (OLD.activo <=> NEW.activo)
     OR NOT (OLD.direccion <=> NEW.direccion) THEN
    INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
    VALUES (NEW.id_cliente, 'UPDATE',
            CONCAT('nombre:', OLD.nombre, '->', NEW.nombre,
                   ' | email:', OLD.email, '->', NEW.email,
                   ' | ciudad:', COALESCE(OLD.ciudad,''), '->', COALESCE(NEW.ciudad,''),
                   ' | activo:', OLD.activo, '->', NEW.activo),
            CURRENT_USER());
  END IF;
END$$

-- 17. trg_log_clientes_delete | AFTER DELETE ON clientes
-- Auditoría de bajas físicas.
DROP TRIGGER IF EXISTS trg_log_clientes_delete$$
CREATE TRIGGER trg_log_clientes_delete
AFTER DELETE ON clientes FOR EACH ROW
BEGIN
  INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
  VALUES (OLD.id_cliente, 'DELETE', CONCAT('Baja: ', OLD.nombre, ' <', OLD.email, '>'), CURRENT_USER());
END$$

-- 18. trg_validar_email_cliente | BEFORE INSERT ON clientes
-- Rechaza correos con formato inválido usando fn_ValidarEmail.
DROP TRIGGER IF EXISTS trg_validar_email_cliente$$
CREATE TRIGGER trg_validar_email_cliente
BEFORE INSERT ON clientes FOR EACH ROW
BEGIN
  IF fn_ValidarEmail(NEW.email) IS NULL OR fn_ValidarEmail(NEW.email) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de correo electrónico inválido';
  END IF;
END$$

-- 19. trg_alerta_stock_bajo | AFTER UPDATE ON productos
-- Genera una alerta al cruzar el umbral de stock mínimo (solo al cruzarlo, no en cada cambio).
DROP TRIGGER IF EXISTS trg_alerta_stock_bajo$$
CREATE TRIGGER trg_alerta_stock_bajo
AFTER UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.stock <= NEW.stock_minimo AND OLD.stock > OLD.stock_minimo THEN
    INSERT INTO alertas (tipo, mensaje)
    VALUES ('STOCK_BAJO',
            CONCAT('Producto ', NEW.sku, ' (', NEW.nombre, ') con stock ', NEW.stock,
                   ' (mínimo ', NEW.stock_minimo, ')'));
  END IF;
END$$

-- 20. trg_validar_resena | BEFORE INSERT ON resenas_producto
-- Solo puede reseñar quien haya recibido (estado Entregado) el producto.
DROP TRIGGER IF EXISTS trg_validar_resena$$
CREATE TRIGGER trg_validar_resena
BEFORE INSERT ON resenas_producto FOR EACH ROW
BEGIN
  IF NOT EXISTS (SELECT 1
                   FROM ventas v
                   JOIN detalle_ventas d ON d.id_venta = v.id_venta
                  WHERE v.id_cliente = NEW.id_cliente
                    AND d.id_producto = NEW.id_producto
                    AND v.estado = 'Entregado') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo clientes con una compra entregada pueden reseñar este producto';
  END IF;
END$$

DELIMITER ;
