-- =====================================================================
-- 03_Funciones.sql
-- 20 funciones almacenadas. Constantes del proyecto:
--   IVA = 19% (precios con IVA incluido) | 1 USD = 4000 COP
--   Envío por peso total: <=1kg 8000 | <=5kg 15000 | <=20kg 30000 | >20kg 50000
-- Entradas inválidas => NULL (las funciones no lanzan errores; los
-- procedimientos y triggers deciden si eso es un error).
-- =====================================================================
USE ecommerce_db;

DELIMITER $$

-- ---------------------------------------------------------------------
-- 1. fn_CalcularTotalVenta
-- Propósito: suma de las líneas de una venta (cantidad * precio congelado).
-- Parámetros: p_id_venta INT. Retorna: DECIMAL(12,2); NULL si la venta no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_CalcularTotalVenta$$
CREATE FUNCTION fn_CalcularTotalVenta(p_id_venta INT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
  DECLARE v_total DECIMAL(12,2);
  IF p_id_venta IS NULL OR NOT EXISTS (SELECT 1 FROM ventas WHERE id_venta = p_id_venta) THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(SUM(cantidad * precio_unitario_congelado), 0) INTO v_total
    FROM detalle_ventas WHERE id_venta = p_id_venta;
  RETURN v_total;
END$$
-- Ejemplo: SELECT fn_CalcularTotalVenta(1);

-- ---------------------------------------------------------------------
-- 2. fn_CalcularIVA
-- Propósito: IVA contenido en un precio que ya lo incluye (19%).
-- Parámetros: p_monto DECIMAL(12,2). Retorna: DECIMAL(12,2); NULL si es negativo o nulo.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_CalcularIVA$$
CREATE FUNCTION fn_CalcularIVA(p_monto DECIMAL(12,2))
RETURNS DECIMAL(12,2)
DETERMINISTIC NO SQL
BEGIN
  IF p_monto IS NULL OR p_monto < 0 THEN RETURN NULL; END IF;
  RETURN ROUND(p_monto - p_monto / 1.19, 2);
END$$
-- Ejemplo: SELECT fn_CalcularIVA(119000);   -- 19000.00

-- ---------------------------------------------------------------------
-- 3. fn_PrecioSinIVA
-- Propósito: base gravable de un precio con IVA incluido.
-- Parámetros: p_precio DECIMAL(12,2). Retorna: DECIMAL(12,2); NULL si es inválido.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_PrecioSinIVA$$
CREATE FUNCTION fn_PrecioSinIVA(p_precio DECIMAL(12,2))
RETURNS DECIMAL(12,2)
DETERMINISTIC NO SQL
BEGIN
  IF p_precio IS NULL OR p_precio < 0 THEN RETURN NULL; END IF;
  RETURN ROUND(p_precio / 1.19, 2);
END$$
-- Ejemplo: SELECT fn_PrecioSinIVA(119000);  -- 100000.00

-- ---------------------------------------------------------------------
-- 4. fn_ConvertirCOPaUSD
-- Propósito: convierte pesos a dólares con la tasa fija 4000 COP/USD.
-- Parámetros: p_monto_cop DECIMAL(14,2). Retorna: DECIMAL(14,2); NULL si es inválido.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_ConvertirCOPaUSD$$
CREATE FUNCTION fn_ConvertirCOPaUSD(p_monto_cop DECIMAL(14,2))
RETURNS DECIMAL(14,2)
DETERMINISTIC NO SQL
BEGIN
  IF p_monto_cop IS NULL OR p_monto_cop < 0 THEN RETURN NULL; END IF;
  RETURN ROUND(p_monto_cop / 4000, 2);
END$$
-- Ejemplo: SELECT fn_ConvertirCOPaUSD(1500000);  -- 375.00

-- ---------------------------------------------------------------------
-- 5. fn_CostoEnvio
-- Propósito: costo de envío según el peso total en kg (tramos del encabezado).
-- Parámetros: p_peso_kg DECIMAL(10,3). Retorna: DECIMAL(12,2); NULL si el peso es negativo/nulo.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_CostoEnvio$$
CREATE FUNCTION fn_CostoEnvio(p_peso_kg DECIMAL(10,3))
RETURNS DECIMAL(12,2)
DETERMINISTIC NO SQL
BEGIN
  IF p_peso_kg IS NULL OR p_peso_kg < 0 THEN RETURN NULL; END IF;
  RETURN CASE WHEN p_peso_kg <= 1  THEN 8000
              WHEN p_peso_kg <= 5  THEN 15000
              WHEN p_peso_kg <= 20 THEN 30000
              ELSE 50000 END;
END$$
-- Ejemplo: SELECT fn_CostoEnvio(3.2);  -- 15000.00

-- ---------------------------------------------------------------------
-- 6. fn_PesoTotalVenta
-- Propósito: peso total (kg) de una venta = suma(cantidad * peso del producto).
-- Parámetros: p_id_venta INT. Retorna: DECIMAL(10,3); NULL si la venta no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_PesoTotalVenta$$
CREATE FUNCTION fn_PesoTotalVenta(p_id_venta INT)
RETURNS DECIMAL(10,3)
READS SQL DATA
BEGIN
  DECLARE v_peso DECIMAL(10,3);
  IF p_id_venta IS NULL OR NOT EXISTS (SELECT 1 FROM ventas WHERE id_venta = p_id_venta) THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(SUM(d.cantidad * p.peso), 0) INTO v_peso
    FROM detalle_ventas d
    JOIN productos p ON p.id_producto = d.id_producto
   WHERE d.id_venta = p_id_venta;
  RETURN v_peso;
END$$
-- Ejemplo: SELECT fn_PesoTotalVenta(1);

-- ---------------------------------------------------------------------
-- 7. fn_MargenProducto
-- Propósito: margen porcentual sobre el precio = (precio - costo) / precio * 100.
-- Parámetros: p_id_producto INT. Retorna: DECIMAL(6,2); NULL si el producto no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_MargenProducto$$
CREATE FUNCTION fn_MargenProducto(p_id_producto INT)
RETURNS DECIMAL(6,2)
READS SQL DATA
BEGIN
  DECLARE v_precio DECIMAL(12,2);
  DECLARE v_costo  DECIMAL(12,2);
  IF p_id_producto IS NULL THEN RETURN NULL; END IF;
  SELECT precio, costo INTO v_precio, v_costo FROM productos WHERE id_producto = p_id_producto;
  IF v_precio IS NULL THEN RETURN NULL; END IF;
  RETURN ROUND((v_precio - v_costo) / v_precio * 100, 2);
END$$
-- Ejemplo: SELECT fn_MargenProducto(1);

-- ---------------------------------------------------------------------
-- 8. fn_PrecioConDescuento
-- Propósito: aplica un descuento porcentual a un precio.
-- Parámetros: p_precio DECIMAL(12,2), p_porcentaje DECIMAL(5,2) (0-100).
-- Retorna: DECIMAL(12,2); NULL si algún parámetro es inválido.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_PrecioConDescuento$$
CREATE FUNCTION fn_PrecioConDescuento(p_precio DECIMAL(12,2), p_porcentaje DECIMAL(5,2))
RETURNS DECIMAL(12,2)
DETERMINISTIC NO SQL
BEGIN
  IF p_precio IS NULL OR p_precio <= 0
     OR p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
    RETURN NULL;
  END IF;
  RETURN ROUND(p_precio * (1 - p_porcentaje / 100), 2);
END$$
-- Ejemplo: SELECT fn_PrecioConDescuento(200000, 15);  -- 170000.00

-- ---------------------------------------------------------------------
-- 9. fn_StockDisponible
-- Propósito: stock físico menos unidades reservadas en carritos Activos
--            (actualizados en las últimas 24 horas).
-- Parámetros: p_id_producto INT. Retorna: INT (mínimo 0); NULL si no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_StockDisponible$$
CREATE FUNCTION fn_StockDisponible(p_id_producto INT)
RETURNS INT
NOT DETERMINISTIC READS SQL DATA
BEGIN
  DECLARE v_stock INT;
  DECLARE v_reservado INT;
  IF p_id_producto IS NULL THEN RETURN NULL; END IF;
  SELECT stock INTO v_stock FROM productos WHERE id_producto = p_id_producto;
  IF v_stock IS NULL THEN RETURN NULL; END IF;
  SELECT COALESCE(SUM(ci.cantidad), 0) INTO v_reservado
    FROM carrito_items ci
    JOIN carritos c ON c.id_carrito = ci.id_carrito
                   AND c.estado = 'Activo'
                   AND c.fecha_actualizacion >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
   WHERE ci.id_producto = p_id_producto;
  RETURN GREATEST(v_stock - v_reservado, 0);
END$$
-- Ejemplo: SELECT fn_StockDisponible(3);

-- ---------------------------------------------------------------------
-- 10. fn_EsStockBajo
-- Propósito: indica si el stock está en o por debajo del mínimo.
-- Parámetros: p_id_producto INT. Retorna: TINYINT (1 sí, 0 no); NULL si no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_EsStockBajo$$
CREATE FUNCTION fn_EsStockBajo(p_id_producto INT)
RETURNS TINYINT
READS SQL DATA
BEGIN
  DECLARE v_bajo TINYINT;
  IF p_id_producto IS NULL THEN RETURN NULL; END IF;
  SELECT (stock <= stock_minimo) INTO v_bajo FROM productos WHERE id_producto = p_id_producto;
  RETURN v_bajo;
END$$
-- Ejemplo: SELECT fn_EsStockBajo(5);  -- 1

-- ---------------------------------------------------------------------
-- 11. fn_EdadCliente
-- Propósito: edad en años cumplidos del cliente.
-- Parámetros: p_id_cliente INT. Retorna: INT; NULL si no existe o sin fecha de nacimiento.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_EdadCliente$$
CREATE FUNCTION fn_EdadCliente(p_id_cliente INT)
RETURNS INT
NOT DETERMINISTIC READS SQL DATA
BEGIN
  DECLARE v_nac DATE;
  IF p_id_cliente IS NULL THEN RETURN NULL; END IF;
  SELECT fecha_nacimiento INTO v_nac FROM clientes WHERE id_cliente = p_id_cliente;
  IF v_nac IS NULL THEN RETURN NULL; END IF;
  RETURN TIMESTAMPDIFF(YEAR, v_nac, CURDATE());
END$$
-- Ejemplo: SELECT fn_EdadCliente(1);

-- ---------------------------------------------------------------------
-- 12. fn_TotalGastadoCliente
-- Propósito: gasto total del cliente en ventas NO canceladas (recalculado desde ventas).
-- Parámetros: p_id_cliente INT. Retorna: DECIMAL(12,2); NULL si el cliente no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_TotalGastadoCliente$$
CREATE FUNCTION fn_TotalGastadoCliente(p_id_cliente INT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
  DECLARE v_total DECIMAL(12,2);
  IF p_id_cliente IS NULL OR NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente) THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(SUM(total), 0) INTO v_total
    FROM ventas WHERE id_cliente = p_id_cliente AND estado <> 'Cancelado';
  RETURN v_total;
END$$
-- Ejemplo: SELECT fn_TotalGastadoCliente(1);

-- ---------------------------------------------------------------------
-- 13. fn_NivelCliente
-- Propósito: nivel de fidelidad según el gasto (Bronce <2M, Plata <10M, Oro <30M, Platino).
-- Parámetros: p_id_cliente INT. Retorna: VARCHAR(10); NULL si el cliente no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_NivelCliente$$
CREATE FUNCTION fn_NivelCliente(p_id_cliente INT)
RETURNS VARCHAR(10)
READS SQL DATA
BEGIN
  DECLARE v_total DECIMAL(12,2);
  SET v_total = fn_TotalGastadoCliente(p_id_cliente);
  IF v_total IS NULL THEN RETURN NULL; END IF;
  RETURN CASE WHEN v_total < 2000000  THEN 'Bronce'
              WHEN v_total < 10000000 THEN 'Plata'
              WHEN v_total < 30000000 THEN 'Oro'
              ELSE 'Platino' END;
END$$
-- Ejemplo: SELECT fn_NivelCliente(1);

-- ---------------------------------------------------------------------
-- 14. fn_DiasDesdeUltimoPedido
-- Propósito: días transcurridos desde la última compra del cliente.
-- Parámetros: p_id_cliente INT. Retorna: INT; NULL si no existe o nunca compró.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_DiasDesdeUltimoPedido$$
CREATE FUNCTION fn_DiasDesdeUltimoPedido(p_id_cliente INT)
RETURNS INT
NOT DETERMINISTIC READS SQL DATA
BEGIN
  DECLARE v_ultimo TIMESTAMP;
  IF p_id_cliente IS NULL THEN RETURN NULL; END IF;
  SELECT fecha_ultimo_pedido INTO v_ultimo FROM clientes WHERE id_cliente = p_id_cliente;
  IF v_ultimo IS NULL THEN RETURN NULL; END IF;
  RETURN DATEDIFF(CURDATE(), DATE(v_ultimo));
END$$
-- Ejemplo: SELECT fn_DiasDesdeUltimoPedido(1);

-- ---------------------------------------------------------------------
-- 15. fn_CalificacionPromedio
-- Propósito: calificación media (1-5) de las reseñas de un producto.
-- Parámetros: p_id_producto INT. Retorna: DECIMAL(3,2); NULL si no hay reseñas.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_CalificacionPromedio$$
CREATE FUNCTION fn_CalificacionPromedio(p_id_producto INT)
RETURNS DECIMAL(3,2)
READS SQL DATA
BEGIN
  DECLARE v_prom DECIMAL(3,2);
  IF p_id_producto IS NULL THEN RETURN NULL; END IF;
  SELECT ROUND(AVG(calificacion), 2) INTO v_prom
    FROM resenas_producto WHERE id_producto = p_id_producto;
  RETURN v_prom;
END$$
-- Ejemplo: SELECT fn_CalificacionPromedio(5);

-- ---------------------------------------------------------------------
-- 16. fn_UnidadesVendidas
-- Propósito: unidades vendidas de un producto en ventas no canceladas.
-- Parámetros: p_id_producto INT. Retorna: INT; NULL si el producto no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_UnidadesVendidas$$
CREATE FUNCTION fn_UnidadesVendidas(p_id_producto INT)
RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_unidades INT;
  IF p_id_producto IS NULL OR NOT EXISTS (SELECT 1 FROM productos WHERE id_producto = p_id_producto) THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(SUM(d.cantidad), 0) INTO v_unidades
    FROM detalle_ventas d
    JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
   WHERE d.id_producto = p_id_producto;
  RETURN v_unidades;
END$$
-- Ejemplo: SELECT fn_UnidadesVendidas(1);

-- ---------------------------------------------------------------------
-- 17. fn_PromocionVigente
-- Propósito: mayor descuento porcentual vigente en una fecha para un producto
--            (promociones activas de su categoría o globales, tipo 'Porcentaje').
-- Parámetros: p_id_producto INT, p_fecha DATE. Retorna: DECIMAL(5,2); 0 si no hay; NULL si no existe.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_PromocionVigente$$
CREATE FUNCTION fn_PromocionVigente(p_id_producto INT, p_fecha DATE)
RETURNS DECIMAL(5,2)
READS SQL DATA
BEGIN
  DECLARE v_cat INT;
  DECLARE v_desc DECIMAL(5,2);
  IF p_id_producto IS NULL OR p_fecha IS NULL THEN RETURN NULL; END IF;
  SELECT id_categoria INTO v_cat FROM productos WHERE id_producto = p_id_producto;
  IF v_cat IS NULL THEN RETURN NULL; END IF;
  SELECT COALESCE(MAX(valor), 0) INTO v_desc
    FROM promociones
   WHERE activa = TRUE AND tipo = 'Porcentaje'
     AND p_fecha BETWEEN fecha_inicio AND fecha_fin
     AND (id_categoria IS NULL OR id_categoria = v_cat);
  RETURN v_desc;
END$$
-- Ejemplo: SELECT fn_PromocionVigente(3, CURDATE());

-- ---------------------------------------------------------------------
-- 18. fn_ValidarEmail
-- Propósito: valida el formato básico de un correo electrónico.
-- Parámetros: p_email VARCHAR(120). Retorna: TINYINT (1 válido, 0 inválido); NULL si es nulo.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_ValidarEmail$$
CREATE FUNCTION fn_ValidarEmail(p_email VARCHAR(120))
RETURNS TINYINT
DETERMINISTIC NO SQL
BEGIN
  IF p_email IS NULL THEN RETURN NULL; END IF;
  RETURN p_email REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$';
END$$
-- Ejemplo: SELECT fn_ValidarEmail('ana@correo.com'), fn_ValidarEmail('ana@');

-- ---------------------------------------------------------------------
-- 19. fn_EsCumpleanos
-- Propósito: indica si la fecha dada es el cumpleaños del cliente (mes y día).
-- Parámetros: p_id_cliente INT, p_fecha DATE. Retorna: TINYINT; NULL si faltan datos.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_EsCumpleanos$$
CREATE FUNCTION fn_EsCumpleanos(p_id_cliente INT, p_fecha DATE)
RETURNS TINYINT
READS SQL DATA
BEGIN
  DECLARE v_nac DATE;
  IF p_id_cliente IS NULL OR p_fecha IS NULL THEN RETURN NULL; END IF;
  SELECT fecha_nacimiento INTO v_nac FROM clientes WHERE id_cliente = p_id_cliente;
  IF v_nac IS NULL THEN RETURN NULL; END IF;
  RETURN (MONTH(v_nac) = MONTH(p_fecha) AND DAY(v_nac) = DAY(p_fecha));
END$$
-- Ejemplo: SELECT fn_EsCumpleanos(1, CURDATE());

-- ---------------------------------------------------------------------
-- 20. fn_DiasParaAgotar
-- Propósito: días estimados hasta agotar el stock según la venta de los últimos 90 días.
-- Parámetros: p_id_producto INT. Retorna: DECIMAL(10,1); NULL si no existe o no tuvo ventas.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_DiasParaAgotar$$
CREATE FUNCTION fn_DiasParaAgotar(p_id_producto INT)
RETURNS DECIMAL(10,1)
NOT DETERMINISTIC READS SQL DATA
BEGIN
  DECLARE v_stock INT;
  DECLARE v_unidades INT;
  IF p_id_producto IS NULL THEN RETURN NULL; END IF;
  SELECT stock INTO v_stock FROM productos WHERE id_producto = p_id_producto;
  IF v_stock IS NULL THEN RETURN NULL; END IF;
  SELECT COALESCE(SUM(d.cantidad), 0) INTO v_unidades
    FROM detalle_ventas d
    JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
   WHERE d.id_producto = p_id_producto
     AND v.fecha_venta >= DATE_SUB(NOW(), INTERVAL 90 DAY);
  IF v_unidades = 0 THEN RETURN NULL; END IF;
  RETURN ROUND(v_stock / (v_unidades / 90), 1);
END$$
-- Ejemplo: SELECT fn_DiasParaAgotar(3);

DELIMITER ;
