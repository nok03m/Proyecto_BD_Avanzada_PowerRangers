-- =====================================================================
-- 05_Triggers.sql
-- 34 triggers para integridad, auditoría y control de stock.
-- Requiere 01 (esquema) y 03 (funciones).
-- Principio: las reglas críticas no dependen solo de procedimientos; también
-- se blindan en la base para impedir bypass mediante DML directo.
-- =====================================================================
USE ecommerce_db;

CREATE TABLE IF NOT EXISTS log_cambios_precio (
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

DROP TRIGGER IF EXISTS trg_prevent_negative_stock$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_prevent_negative_stock
BEFORE UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.stock < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock insuficiente: la operación dejaría el stock en negativo';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_descontar_stock_venta$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_descontar_stock_venta
AFTER INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  DECLARE v_control_stock VARCHAR(20);
  SELECT control_stock INTO v_control_stock FROM ventas WHERE id_venta = NEW.id_venta;
  IF v_control_stock = 'Integrado' THEN
    UPDATE productos SET stock = stock - NEW.cantidad WHERE id_producto = NEW.id_producto;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_restaurar_stock_venta_cancelada$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_restaurar_stock_venta_cancelada
AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
  IF NEW.estado = 'Cancelado' AND OLD.estado <> 'Cancelado' AND NEW.control_stock = 'Integrado' THEN
    UPDATE productos p
      JOIN detalle_ventas d ON d.id_producto = p.id_producto
       SET p.stock = p.stock + d.cantidad
     WHERE d.id_venta = NEW.id_venta;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_log_cambio_precio$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_log_cambio_precio
AFTER UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.precio <> OLD.precio THEN
    INSERT INTO log_cambios_precio (id_producto, precio_anterior, precio_nuevo, usuario)
    VALUES (NEW.id_producto, OLD.precio, NEW.precio, USER());
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_limitar_cambio_precio$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_limitar_cambio_precio
BEFORE UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.precio <> OLD.precio
     AND (NEW.precio > OLD.precio * 2 OR NEW.precio < OLD.precio * 0.3) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cambio de precio fuera de rango permitido (entre 30% y 200% del precio actual)';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_congelar_precio_detalle$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_congelar_precio_detalle
BEFORE INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  IF NEW.precio_unitario_congelado IS NULL OR NEW.precio_unitario_congelado <= 0 THEN
    SET NEW.precio_unitario_congelado = (SELECT precio FROM productos WHERE id_producto = NEW.id_producto);
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_detalle_venta$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_detalle_venta
BEFORE INSERT ON detalle_ventas FOR EACH ROW FOLLOWS trg_congelar_precio_detalle
BEGIN
  DECLARE v_estado VARCHAR(20);
  DECLARE v_activo BOOLEAN;
  DECLARE v_stock INT;
  DECLARE v_control_stock VARCHAR(20);
  DECLARE v_precio DECIMAL(12,2);

  SELECT estado, control_stock INTO v_estado, v_control_stock
    FROM ventas WHERE id_venta = NEW.id_venta;
  IF v_estado IS NULL OR v_estado <> 'Pendiente' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se pueden agregar líneas a ventas Pendientes';
  END IF;
  IF v_control_stock <> 'Integrado' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las ventas históricas son de solo lectura';
  END IF;

  SELECT activo, stock, precio INTO v_activo, v_stock, v_precio
    FROM productos WHERE id_producto = NEW.id_producto;
  IF v_activo IS NULL OR v_activo = FALSE THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe o está inactivo';
  END IF;
  IF v_stock < NEW.cantidad THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock insuficiente para la línea';
  END IF;
  IF NEW.precio_lista_congelado <> v_precio THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio de lista congelado debe coincidir con el precio vigente del producto';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_actualizar_total_venta$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_actualizar_total_venta
AFTER INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  UPDATE ventas
     SET total = fn_CalcularTotalVenta(NEW.id_venta),
         costo_envio = fn_CostoEnvio(fn_PesoTotalVenta(NEW.id_venta))
   WHERE id_venta = NEW.id_venta;
END$$

DROP TRIGGER IF EXISTS trg_prevent_update_detalle$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_prevent_update_detalle
BEFORE UPDATE ON detalle_ventas FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las líneas de venta no se pueden modificar; cancele la venta y cree una nueva';
END$$

DROP TRIGGER IF EXISTS trg_prevent_delete_detalle$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_prevent_delete_detalle
BEFORE DELETE ON detalle_ventas FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las líneas de venta no se pueden eliminar; cancele la venta';
END$$

DROP TRIGGER IF EXISTS trg_actualizar_total_gastado_cliente$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_actualizar_total_gastado_cliente
AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
  DECLARE v_total DECIMAL(12,2);
  DECLARE v_ultimo TIMESTAMP;
  IF OLD.estado <> NEW.estado OR OLD.total <> NEW.total THEN
    SELECT COALESCE(SUM(CASE WHEN v2.estado IN ('Pagado','Enviado','Entregado') THEN v2.total END),0),
           MAX(CASE WHEN v2.estado IN ('Pagado','Enviado','Entregado') THEN v2.fecha_venta END)
      INTO v_total, v_ultimo
      FROM ventas v2
     WHERE v2.id_cliente = NEW.id_cliente;
    UPDATE clientes
       SET total_gastado = v_total,
           fecha_ultimo_pedido = v_ultimo
     WHERE id_cliente = NEW.id_cliente;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_log_estado_pedido$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_log_estado_pedido
AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
  IF NEW.estado <> OLD.estado THEN
    INSERT INTO log_estado_pedido (id_venta, estado_anterior, estado_nuevo, usuario)
    VALUES (NEW.id_venta, OLD.estado, NEW.estado, USER());
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_transicion_estado$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_transicion_estado
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

DROP TRIGGER IF EXISTS trg_actualizar_ultimo_pedido$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_actualizar_ultimo_pedido
AFTER INSERT ON ventas FOR EACH ROW
BEGIN
  IF NEW.estado IN ('Pagado','Enviado','Entregado') THEN
    UPDATE clientes
       SET fecha_ultimo_pedido = GREATEST(COALESCE(fecha_ultimo_pedido, NEW.fecha_venta), NEW.fecha_venta)
     WHERE id_cliente = NEW.id_cliente;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_log_clientes_insert$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_log_clientes_insert
AFTER INSERT ON clientes FOR EACH ROW
BEGIN
  INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
  VALUES (NEW.id_cliente, 'INSERT', CONCAT('Alta: ', NEW.nombre, ' <', NEW.email, '>'), USER());
END$$

DROP TRIGGER IF EXISTS trg_log_clientes_update$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_log_clientes_update
AFTER UPDATE ON clientes FOR EACH ROW
BEGIN
  IF NOT (OLD.nombre <=> NEW.nombre) OR NOT (OLD.email <=> NEW.email)
     OR NOT (OLD.ciudad <=> NEW.ciudad) OR NOT (OLD.activo <=> NEW.activo)
     OR NOT (OLD.direccion <=> NEW.direccion)
     OR NOT (OLD.region <=> NEW.region)
     OR NOT (OLD.referido_por <=> NEW.referido_por) THEN
    INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
    VALUES (NEW.id_cliente, 'UPDATE',
            CONCAT('nombre:', OLD.nombre, '->', NEW.nombre,
                   ' | email:', OLD.email, '->', NEW.email,
                   ' | ciudad:', COALESCE(OLD.ciudad,''), '->', COALESCE(NEW.ciudad,''),
                   ' | region:', COALESCE(OLD.region,''), '->', COALESCE(NEW.region,''),
                   ' | activo:', OLD.activo, '->', NEW.activo),
            USER());
  END IF;

  -- La auditoría de email/dirección vive en trg_audit_cliente_after_update.sql
END$$

DROP TRIGGER IF EXISTS trg_log_clientes_delete$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_log_clientes_delete
AFTER DELETE ON clientes FOR EACH ROW
BEGIN
  INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
  VALUES (OLD.id_cliente, 'DELETE', CONCAT('Baja: ', OLD.nombre, ' <', OLD.email, '>'), USER());
END$$

DROP TRIGGER IF EXISTS trg_validar_email_cliente$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_email_cliente
BEFORE INSERT ON clientes FOR EACH ROW
BEGIN
  IF NEW.email IS NULL OR fn_ValidarEmail(TRIM(NEW.email)) <> 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de correo electrónico inválido';
  END IF;
  SET NEW.email = LOWER(TRIM(NEW.email));
END$$

DROP TRIGGER IF EXISTS trg_alerta_stock_bajo$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_alerta_stock_bajo
AFTER UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.stock <= NEW.stock_minimo AND OLD.stock > OLD.stock_minimo THEN
    INSERT INTO alertas (tipo, mensaje)
    VALUES ('STOCK_BAJO',
            CONCAT('Producto ', NEW.sku, ' (', NEW.nombre, ') con stock ', NEW.stock,
                   ' (mínimo ', NEW.stock_minimo, ')'));
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_resena$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_resena
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

DROP TRIGGER IF EXISTS trg_prevent_delete_venta$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_prevent_delete_venta
BEFORE DELETE ON ventas FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las ventas no se pueden eliminar; use el archivado histórico';
END$$

DROP TRIGGER IF EXISTS trg_validar_venta_insert$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_venta_insert
BEFORE INSERT ON ventas FOR EACH ROW
BEGIN
  DECLARE v_suc INT;
  DECLARE v_activo BOOLEAN;
  IF NEW.control_stock <> 'Integrado' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las ventas nuevas deben utilizar control_stock=Integrado';
  END IF;
  IF NEW.total <> 0 OR NEW.descuento_total <> 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Una venta nueva debe iniciar con total y descuento en cero';
  END IF;
  IF NEW.control_stock = 'Integrado' THEN
    SELECT id_sucursal, activo INTO v_suc, v_activo
      FROM clientes WHERE id_cliente = NEW.id_cliente;
    IF v_activo IS NULL OR v_activo = FALSE OR v_suc IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente debe existir, estar activo y tener sucursal';
    END IF;
    IF NEW.id_sucursal <> v_suc THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta debe pertenecer a la sucursal del cliente';
    END IF;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_venta_update$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_venta_update
BEFORE UPDATE ON ventas FOR EACH ROW
BEGIN
  DECLARE v_subtotal DECIMAL(12,2);
  DECLARE v_envio_esperado DECIMAL(12,2);
  IF NEW.id_cliente <> OLD.id_cliente THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente de una venta es inmutable';
  END IF;
  IF NEW.id_sucursal <> OLD.id_sucursal THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La sucursal de una venta es inmutable';
  END IF;
  IF NEW.fecha_venta <> OLD.fecha_venta THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La fecha de una venta es inmutable';
  END IF;
  IF NEW.control_stock <> OLD.control_stock THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El modo de control de stock de una venta es inmutable';
  END IF;
  SELECT COALESCE(SUM(cantidad * precio_unitario_congelado),0)
    INTO v_subtotal FROM detalle_ventas WHERE id_venta = NEW.id_venta;
  IF NEW.descuento_total < 0 OR NEW.descuento_total > v_subtotal THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El descuento total no puede superar el subtotal';
  END IF;
  IF NEW.descuento_total <> OLD.descuento_total AND OLD.estado <> 'Pendiente' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El descuento total solo se puede ajustar mientras la venta está Pendiente';
  END IF;
  IF NEW.total <> ROUND(v_subtotal - NEW.descuento_total,2) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Total de venta inconsistente con sus líneas y descuento';
  END IF;
  IF NEW.control_stock = 'Integrado' THEN
    SET v_envio_esperado = fn_CostoEnvio(fn_PesoTotalVenta(NEW.id_venta));
    IF NEW.costo_envio <> v_envio_esperado THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Costo de envío inconsistente con el peso de las líneas';
    END IF;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_agregados_cliente$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_agregados_cliente
BEFORE UPDATE ON clientes FOR EACH ROW
BEGIN
  DECLARE v_total DECIMAL(12,2);
  DECLARE v_ultimo TIMESTAMP;
  IF NEW.id_sucursal <> OLD.id_sucursal THEN
    IF EXISTS (SELECT 1 FROM ventas WHERE id_cliente = NEW.id_cliente) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La sucursal del cliente no se puede cambiar después de registrar ventas';
    END IF;
  END IF;
  SELECT COALESCE(SUM(CASE WHEN v.estado IN ('Pagado','Enviado','Entregado') THEN v.total END),0),
         MAX(CASE WHEN v.estado IN ('Pagado','Enviado','Entregado') THEN v.fecha_venta END)
    INTO v_total, v_ultimo
    FROM ventas v WHERE v.id_cliente = NEW.id_cliente;
  IF ABS(NEW.total_gastado - v_total) > 0.01 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'total_gastado es un dato derivado y no coincide con ventas';
  END IF;
  IF NOT (NEW.fecha_ultimo_pedido <=> v_ultimo) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fecha_ultimo_pedido es un dato derivado y no coincide con ventas';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_email_cliente_update$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_email_cliente_update
BEFORE UPDATE ON clientes FOR EACH ROW
BEGIN
  IF NEW.email IS NULL OR fn_ValidarEmail(TRIM(NEW.email)) <> 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de correo electrónico inválido';
  END IF;
  SET NEW.email = LOWER(TRIM(NEW.email));
  IF NEW.password_hash IS NULL OR CHAR_LENGTH(NEW.password_hash) < 20
     OR NEW.password_hash NOT REGEXP '^(\\$[A-Za-z0-9][A-Za-z0-9_-]*\\$|\\$2[aby]\\$)' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'password_hash inválido: debe conservar formato PHC';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_pago_insert$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_pago_insert
BEFORE INSERT ON pagos FOR EACH ROW
BEGIN
  DECLARE v_estado VARCHAR(20);
  DECLARE v_total DECIMAL(12,2);
  DECLARE v_envio DECIMAL(12,2);
  SELECT estado,total,costo_envio INTO v_estado,v_total,v_envio
    FROM ventas WHERE id_venta = NEW.id_venta;
  IF v_estado IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta del pago no existe';
  END IF;
  IF NEW.monto <> ROUND(v_total + v_envio,2) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El monto del pago debe coincidir con total + envío';
  END IF;
  IF NEW.monto_reembolsado < 0 OR NEW.monto_reembolsado > NEW.monto THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Monto reembolsado inválido';
  END IF;
  IF NEW.estado = 'Aprobado' AND v_estado <> 'Pendiente' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo una venta Pendiente puede recibir un pago Aprobado nuevo';
  END IF;
  IF NEW.estado = 'Pendiente' AND NEW.monto_reembolsado <> 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un pago Pendiente no puede estar reembolsado';
  END IF;
  IF NEW.estado = 'Reembolsado' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un pago Reembolsado debe originarse desde un pago Aprobado mediante la operación de reembolso';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_pago_update$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_pago_update
BEFORE UPDATE ON pagos FOR EACH ROW
BEGIN
  DECLARE v_estado_venta VARCHAR(20);
  DECLARE v_total DECIMAL(12,2);
  DECLARE v_envio DECIMAL(12,2);
  IF NEW.id_venta <> OLD.id_venta THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pago no puede cambiar de venta';
  END IF;
  SELECT estado,total,costo_envio INTO v_estado_venta,v_total,v_envio
    FROM ventas WHERE id_venta = NEW.id_venta;
  IF NEW.monto <> ROUND(v_total + v_envio,2) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El monto del pago debe coincidir con total + envío';
  END IF;
  IF NEW.monto_reembolsado < OLD.monto_reembolsado OR NEW.monto_reembolsado > NEW.monto THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El monto reembolsado solo puede aumentar y no superar el pago';
  END IF;
  IF OLD.estado = 'Rechazado' AND NEW.estado <> 'Rechazado' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un pago Rechazado es terminal';
  END IF;
  IF OLD.estado = 'Reembolsado' AND NEW.estado <> 'Reembolsado' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un pago Reembolsado es terminal';
  END IF;
  IF OLD.estado = 'Pendiente' AND NEW.estado NOT IN ('Pendiente','Aprobado','Rechazado') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transición de pago inválida';
  END IF;
  IF OLD.estado = 'Aprobado' AND NEW.estado NOT IN ('Aprobado','Reembolsado') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transición de pago inválida';
  END IF;
  IF NEW.estado = 'Pendiente' AND NEW.monto_reembolsado <> 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un pago Pendiente no puede tener reembolso';
  END IF;
  IF NEW.estado = 'Reembolsado' AND NEW.monto_reembolsado <> NEW.monto THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pago Reembolsado debe estar completamente reembolsado';
  END IF;
  IF OLD.estado <> 'Pendiente' AND (
       NEW.monto <> OLD.monto OR NEW.metodo <> OLD.metodo OR NEW.referencia <> OLD.referencia
       OR NEW.fecha_pago <> OLD.fecha_pago) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Datos principales del pago son inmutables después de Pendiente';
  END IF;
  IF NEW.estado = 'Aprobado' AND v_estado_venta NOT IN ('Pendiente','Entregado','Enviado','Pagado') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pago Aprobado no es compatible con el estado de la venta';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_aplicar_pago_aprobado_insert$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_aplicar_pago_aprobado_insert
AFTER INSERT ON pagos FOR EACH ROW
BEGIN
  IF NEW.estado = 'Aprobado' THEN
    UPDATE ventas SET estado = 'Pagado'
     WHERE id_venta = NEW.id_venta AND estado = 'Pendiente';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_aplicar_pago_aprobado_update$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_aplicar_pago_aprobado_update
AFTER UPDATE ON pagos FOR EACH ROW
BEGIN
  IF NEW.estado = 'Aprobado' AND OLD.estado <> 'Aprobado' THEN
    UPDATE ventas SET estado = 'Pagado'
     WHERE id_venta = NEW.id_venta AND estado = 'Pendiente';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_validar_devolucion_insert$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_validar_devolucion_insert
BEFORE INSERT ON devoluciones FOR EACH ROW
BEGIN
  DECLARE v_estado VARCHAR(20);
  DECLARE v_comprada INT;
  DECLARE v_devuelta INT;
  DECLARE v_pago INT;
  SELECT estado INTO v_estado FROM ventas WHERE id_venta = NEW.id_venta;
  IF v_estado <> 'Entregado' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se devuelven ventas Entregadas';
  END IF;
  SELECT cantidad INTO v_comprada FROM detalle_ventas
   WHERE id_venta = NEW.id_venta AND id_producto = NEW.id_producto;
  IF v_comprada IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no pertenece a la venta';
  END IF;
  SELECT COALESCE(SUM(cantidad),0) INTO v_devuelta FROM devoluciones
   WHERE id_venta = NEW.id_venta AND id_producto = NEW.id_producto AND estado='Aprobada';
  IF NEW.cantidad > v_comprada - v_devuelta THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad supera lo pendiente por devolver';
  END IF;
  IF NEW.estado = 'Aprobada' THEN
    SELECT COUNT(*) INTO v_pago FROM pagos
     WHERE id_venta = NEW.id_venta AND estado IN ('Aprobado','Reembolsado');
    IF v_pago = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no tiene pago reembolsable';
    END IF;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_aplicar_devolucion_aprobada$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_aplicar_devolucion_aprobada
AFTER INSERT ON devoluciones FOR EACH ROW
BEGIN
  DECLARE v_subtotal DECIMAL(12,2);
  DECLARE v_descuento DECIMAL(12,2);
  DECLARE v_precio DECIMAL(12,2);
  DECLARE v_linea_bruta DECIMAL(12,2);
  DECLARE v_reembolso DECIMAL(12,2);
  DECLARE v_pendiente INT;

  IF NEW.estado = 'Aprobada' THEN
    SELECT v.descuento_total,
           COALESCE(SUM(d.cantidad * d.precio_unitario_congelado),0)
      INTO v_descuento, v_subtotal
      FROM ventas v
      JOIN detalle_ventas d ON d.id_venta = v.id_venta
     WHERE v.id_venta = NEW.id_venta
     GROUP BY v.id_venta, v.descuento_total;

    SELECT precio_unitario_congelado INTO v_precio
      FROM detalle_ventas
     WHERE id_venta = NEW.id_venta AND id_producto = NEW.id_producto;

    SET v_linea_bruta = ROUND(v_precio * NEW.cantidad, 2);
    SET v_reembolso = ROUND(v_linea_bruta -
                            CASE WHEN v_subtotal = 0 THEN 0
                                 ELSE v_descuento * v_linea_bruta / v_subtotal END, 2);

    UPDATE productos
       SET stock = stock + NEW.cantidad
     WHERE id_producto = NEW.id_producto;

    INSERT INTO ajustes_stock (id_producto, cantidad_ajuste, motivo, usuario)
    VALUES (NEW.id_producto, NEW.cantidad,
            CONCAT('Devolución venta ', NEW.id_venta), USER());

    UPDATE pagos
       SET estado = CASE WHEN monto_reembolsado + v_reembolso >= monto
                         THEN 'Reembolsado' ELSE 'Aprobado' END,
           monto_reembolsado = monto_reembolsado + v_reembolso
     WHERE id_venta = NEW.id_venta;

    SELECT COUNT(*) INTO v_pendiente
      FROM detalle_ventas d
      LEFT JOIN (
        SELECT id_producto, SUM(cantidad) AS devuelto
          FROM devoluciones
         WHERE id_venta = NEW.id_venta AND estado = 'Aprobada'
         GROUP BY id_producto
      ) r ON r.id_producto = d.id_producto
     WHERE d.id_venta = NEW.id_venta AND d.cantidad > COALESCE(r.devuelto,0);

    IF v_pendiente = 0 THEN
      UPDATE ventas SET estado = 'Devuelto' WHERE id_venta = NEW.id_venta;
    END IF;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_prevent_update_devolucion$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_prevent_update_devolucion
BEFORE UPDATE ON devoluciones FOR EACH ROW
BEGIN
  DECLARE v_estado_venta VARCHAR(20);
  DECLARE v_comprada INT;
  DECLARE v_devuelta INT;
  DECLARE v_pago INT;
  DECLARE v_pago_monto DECIMAL(12,2);
  DECLARE v_reembolsado DECIMAL(12,2);
  DECLARE v_subtotal DECIMAL(12,2);
  DECLARE v_descuento DECIMAL(12,2);
  DECLARE v_precio DECIMAL(12,2);
  DECLARE v_linea_bruta DECIMAL(12,2);
  DECLARE v_reembolso DECIMAL(12,2);
  DECLARE v_pendiente INT;
  DECLARE v_suc INT;

  IF NEW.id_venta <> OLD.id_venta
     OR NEW.id_producto <> OLD.id_producto
     OR NEW.cantidad <> OLD.cantidad
     OR NOT (NEW.motivo <=> OLD.motivo)
     OR NEW.fecha <> OLD.fecha THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo puede cambiar el estado de la devolución';
  END IF;

  IF OLD.estado = 'Aprobada' AND NEW.estado <> 'Aprobada' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Una devolución Aprobada es terminal';
  END IF;
  IF OLD.estado = 'Rechazada' AND NEW.estado <> 'Rechazada' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Una devolución Rechazada es terminal';
  END IF;
  IF OLD.estado = 'Solicitada' AND NEW.estado NOT IN ('Solicitada','Aprobada','Rechazada') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transición de devolución inválida';
  END IF;

  IF OLD.estado = 'Solicitada' AND NEW.estado = 'Aprobada' THEN
    SELECT estado, id_sucursal INTO v_estado_venta, v_suc
      FROM ventas WHERE id_venta = NEW.id_venta;
    IF v_estado_venta <> 'Entregado' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se devuelven ventas Entregadas';
    END IF;
    IF EXISTS (SELECT 1 FROM usuario_sucursal
               WHERE usuario = SUBSTRING_INDEX(USER(), '@', 1))
       AND NOT EXISTS (SELECT 1 FROM usuario_sucursal
                       WHERE usuario = SUBSTRING_INDEX(USER(), '@', 1) AND id_sucursal = v_suc) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario no tiene acceso a la sucursal de la devolución';
    END IF;

    SELECT cantidad INTO v_comprada
      FROM detalle_ventas
     WHERE id_venta = NEW.id_venta AND id_producto = NEW.id_producto;
    IF v_comprada IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no pertenece a la venta';
    END IF;
    SELECT COALESCE(SUM(cantidad),0) INTO v_devuelta
      FROM devoluciones
     WHERE id_venta = NEW.id_venta AND id_producto = NEW.id_producto
       AND estado = 'Aprobada' AND id_devolucion <> NEW.id_devolucion;
    IF NEW.cantidad > v_comprada - v_devuelta THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad supera lo pendiente por devolver';
    END IF;

    SELECT COUNT(*), MAX(monto), MAX(monto_reembolsado)
      INTO v_pago, v_pago_monto, v_reembolsado
      FROM pagos
     WHERE id_venta = NEW.id_venta AND estado IN ('Aprobado','Reembolsado');
    IF v_pago = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no tiene pago reembolsable';
    END IF;

    SELECT v.descuento_total,
           COALESCE(SUM(d.cantidad * d.precio_unitario_congelado),0)
      INTO v_descuento, v_subtotal
      FROM ventas v
      JOIN detalle_ventas d ON d.id_venta = v.id_venta
     WHERE v.id_venta = NEW.id_venta
     GROUP BY v.id_venta, v.descuento_total;
    SELECT precio_unitario_congelado INTO v_precio
      FROM detalle_ventas
     WHERE id_venta = NEW.id_venta AND id_producto = NEW.id_producto;
    SET v_linea_bruta = ROUND(v_precio * NEW.cantidad, 2);
    SET v_reembolso = ROUND(v_linea_bruta -
                            CASE WHEN v_subtotal = 0 THEN 0
                                 ELSE v_descuento * v_linea_bruta / v_subtotal END, 2);
    IF v_reembolso <= 0 OR v_reembolsado + v_reembolso > v_pago_monto THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El reembolso calculado no es válido';
    END IF;

    UPDATE productos
       SET stock = stock + NEW.cantidad
     WHERE id_producto = NEW.id_producto;
    INSERT INTO ajustes_stock (id_producto, cantidad_ajuste, motivo, usuario)
    VALUES (NEW.id_producto, NEW.cantidad,
            CONCAT('Devolución venta ', NEW.id_venta), USER());
    UPDATE pagos
       SET estado = CASE WHEN monto_reembolsado + v_reembolso >= monto
                         THEN 'Reembolsado' ELSE 'Aprobado' END,
           monto_reembolsado = monto_reembolsado + v_reembolso
     WHERE id_venta = NEW.id_venta;

    SELECT COUNT(*) INTO v_pendiente
      FROM detalle_ventas d
      LEFT JOIN (
        SELECT id_producto, SUM(cantidad) AS devuelto
          FROM devoluciones
         WHERE id_venta = NEW.id_venta AND estado = 'Aprobada' AND id_devolucion <> NEW.id_devolucion
         GROUP BY id_producto
      ) r ON r.id_producto = d.id_producto
     WHERE d.id_venta = NEW.id_venta AND d.cantidad > COALESCE(r.devuelto,0) + NEW.cantidad;
    IF v_pendiente = 0 THEN
      UPDATE ventas SET estado = 'Devuelto' WHERE id_venta = NEW.id_venta;
    END IF;
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_prevent_delete_devolucion$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_prevent_delete_devolucion
BEFORE DELETE ON devoluciones FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las devoluciones no se pueden eliminar; conserve el registro de auditoría';
END$$

DROP TRIGGER IF EXISTS trg_prevent_delete_pago$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_prevent_delete_pago
BEFORE DELETE ON pagos FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Los pagos no se pueden eliminar; conserve el historial financiero';
END$$

DELIMITER ;
