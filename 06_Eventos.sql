-- =====================================================================
-- 06_Eventos.sql
-- 20 eventos programados. El nombre indica la frecuencia:
--   ev_horario_* (cada hora) | ev_diario_* | ev_semanal_* | ev_mensual_* | ev_trimestral_*
-- Todos son idempotentes (DROP EVENT IF EXISTS + CREATE) y usan ON COMPLETION PRESERVE.
-- Los eventos que llaman a sp_* las resuelven en tiempo de ejecución: los procedimientos
-- se crean en 07, que corre después de este archivo (no se validan al crear el evento).
-- SIMULACIONES (MySQL no las ofrece nativamente): ev_diario_backup_simulado,
--   ev_semanal_optimizar_tablas_simulado y ev_diario_ranking_productos (vista materializada
--   emulada con una tabla). Un backup real se hace con mysqldump / MySQL Enterprise Backup.
-- Requiere privilegio EVENT y SYSTEM_VARIABLES_ADMIN (o SUPER) para activar el planificador.
-- =====================================================================
USE ecommerce_db;

-- Tabla asignada a este archivo
DROP TABLE IF EXISTS reporte_ventas_semanales;
CREATE TABLE reporte_ventas_semanales (
  id_reporte      INT AUTO_INCREMENT PRIMARY KEY,
  anio_semana     CHAR(6) NOT NULL,                 -- formato YYYYWW (modo 3 de YEARWEEK)
  fecha_inicio    DATE NOT NULL,
  fecha_fin       DATE NOT NULL,
  num_ventas      INT NOT NULL DEFAULT 0,
  ingresos        DECIMAL(14,2) NOT NULL DEFAULT 0,
  ticket_promedio DECIMAL(12,2) NOT NULL DEFAULT 0,
  fecha_generacion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_rvs_semana (anio_semana)
) ENGINE=InnoDB;

-- Activa el planificador (no persiste tras reinicio; para persistir: SET PERSIST event_scheduler = ON;)
SET GLOBAL event_scheduler = ON;

DELIMITER $$

-- ===================== CADA HORA =====================

-- 1. ev_horario_alertas_stock_bajo
-- Cada hora: alerta por cada producto con stock <= mínimo que no tenga alerta pendiente.
DROP EVENT IF EXISTS ev_horario_alertas_stock_bajo$$
CREATE DEFINER='root'@'localhost' EVENT ev_horario_alertas_stock_bajo
ON SCHEDULE EVERY 1 HOUR STARTS (CURRENT_TIMESTAMP + INTERVAL 1 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
  INSERT INTO alertas (tipo, mensaje)
  SELECT 'STOCK_BAJO',
         CONCAT('Producto ', p.sku, ' (', p.nombre, ') con stock ', p.stock, ' (mínimo ', p.stock_minimo, ')')
    FROM productos p
   WHERE p.activo = TRUE AND p.stock <= p.stock_minimo
     AND NOT EXISTS (SELECT 1 FROM alertas a
                      WHERE a.tipo = 'STOCK_BAJO' AND a.atendida = FALSE
                        AND a.mensaje LIKE CONCAT('Producto ', p.sku, ' %'))$$

-- 2. ev_horario_cancelar_pendientes_vencidos
-- Cada hora: cancela ventas Pendientes de más de 48 h y marca su pago como Rechazado.
-- Solo aplica a ventas Integradas; las filas Históricas nunca se modifican por automatismos operativos.
DROP EVENT IF EXISTS ev_horario_cancelar_pendientes_vencidos$$
CREATE DEFINER='root'@'localhost' EVENT ev_horario_cancelar_pendientes_vencidos
ON SCHEDULE EVERY 1 HOUR STARTS (CURRENT_TIMESTAMP + INTERVAL 1 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
BEGIN
  UPDATE pagos p
    JOIN ventas v ON v.id_venta = p.id_venta
     SET p.estado = 'Rechazado'
   WHERE v.estado = 'Pendiente'
     AND v.control_stock = 'Integrado'
     AND v.fecha_venta < DATE_SUB(NOW(), INTERVAL 48 HOUR)
     AND p.estado = 'Pendiente';

  UPDATE ventas
     SET estado = 'Cancelado'
   WHERE estado = 'Pendiente'
     AND control_stock = 'Integrado'
     AND fecha_venta < DATE_SUB(NOW(), INTERVAL 48 HOUR);
END$$

-- 3. ev_horario_marcar_carritos_abandonados
-- Cada hora: marca como Abandonado los carritos Activos sin cambios en 24 h.
DROP EVENT IF EXISTS ev_horario_marcar_carritos_abandonados$$
CREATE DEFINER='root'@'localhost' EVENT ev_horario_marcar_carritos_abandonados
ON SCHEDULE EVERY 1 HOUR STARTS (CURRENT_TIMESTAMP + INTERVAL 1 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
  UPDATE carritos SET estado = 'Abandonado'
   WHERE estado = 'Activo' AND fecha_actualizacion < DATE_SUB(NOW(), INTERVAL 24 HOUR)$$

-- ===================== DIARIOS =====================

-- 4. ev_diario_resumen_ventas
-- Cada día 01:00: consolida en resumen_ventas_diarias las ventas de ayer (sin canceladas).
DROP EVENT IF EXISTS ev_diario_resumen_ventas$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_resumen_ventas
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 1 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
  REPLACE INTO resumen_ventas_diarias (fecha, num_ventas, unidades, total_ventas)
  SELECT x.dia, x.num_ventas, COALESCE(u.unidades, 0), x.ingresos
    FROM (SELECT DATE(fecha_venta) AS dia, COUNT(*) AS num_ventas, SUM(total) AS ingresos
            FROM ventas
           WHERE estado IN ('Pagado','Enviado','Entregado')
             AND fecha_venta >= DATE_SUB(CURRENT_DATE, INTERVAL 1 DAY)
             AND fecha_venta <  CURRENT_DATE
           GROUP BY DATE(fecha_venta)) x
    LEFT JOIN (SELECT DATE(v.fecha_venta) AS dia, SUM(d.cantidad) AS unidades
                 FROM ventas v
                 JOIN detalle_ventas d ON d.id_venta = v.id_venta
                WHERE v.estado IN ('Pagado','Enviado','Entregado')
                  AND v.fecha_venta >= DATE_SUB(CURRENT_DATE, INTERVAL 1 DAY)
                  AND v.fecha_venta <  CURRENT_DATE
                GROUP BY DATE(v.fecha_venta)) u ON u.dia = x.dia$$

-- 5. ev_diario_ranking_productos
-- Cada día 01:30: refresca ranking_productos (vista materializada simulada).
DROP EVENT IF EXISTS ev_diario_ranking_productos$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_ranking_productos
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 90 MINUTE)
ON COMPLETION PRESERVE ENABLE
DO CALL sp_ActualizarRankingProductos()$$

-- 6. ev_diario_reporte_reabastecimiento
-- Cada día 02:00: genera la lista de productos a reponer.
DROP EVENT IF EXISTS ev_diario_reporte_reabastecimiento$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_reporte_reabastecimiento
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 2 HOUR)
ON COMPLETION PRESERVE ENABLE
DO CALL sp_GenerarReporteReabastecimiento()$$

-- 7. ev_diario_lista_cumpleanos
-- Cada día 06:00: registra los clientes que cumplen años hoy (una fila por cliente y año).
DROP EVENT IF EXISTS ev_diario_lista_cumpleanos$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_lista_cumpleanos
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 6 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
  INSERT INTO lista_cumpleanos (id_cliente, nombre, fecha_nacimiento, anio)
  SELECT c.id_cliente, c.nombre, c.fecha_nacimiento, YEAR(CURRENT_DATE)
    FROM clientes c
   WHERE c.activo = TRUE AND c.fecha_nacimiento IS NOT NULL
     AND MONTH(c.fecha_nacimiento) = MONTH(CURRENT_DATE)
     AND DAY(c.fecha_nacimiento) = DAY(CURRENT_DATE)
     AND NOT EXISTS (SELECT 1 FROM lista_cumpleanos l
                      WHERE l.id_cliente = c.id_cliente AND l.anio = YEAR(CURRENT_DATE))$$

-- 8. ev_diario_registrar_tamano_bd
-- Cada día 02:30: guarda el tamaño de la base en MB.
DROP EVENT IF EXISTS ev_diario_registrar_tamano_bd$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_registrar_tamano_bd
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 150 MINUTE)
ON COMPLETION PRESERVE ENABLE
DO
  INSERT INTO log_tamano_bd (tamano_mb)
  SELECT ROUND(COALESCE(SUM(data_length + index_length), 0) / 1024 / 1024, 2)
    FROM information_schema.TABLES
   WHERE table_schema = 'ecommerce_db'$$

-- 9. ev_diario_actualizar_promociones
-- Cada día 00:05: activa las promociones vigentes y desactiva las vencidas.
DROP EVENT IF EXISTS ev_diario_actualizar_promociones$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_actualizar_promociones
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 5 MINUTE)
ON COMPLETION PRESERVE ENABLE
DO
  UPDATE promociones
     SET activa = (CURRENT_DATE BETWEEN fecha_inicio AND fecha_fin)$$

-- 10. ev_diario_backup_simulado
-- SIMULACIÓN: deja constancia en alertas de que corresponde ejecutar el respaldo real
-- (mysqldump ecommerce_db > backup.sql desde el sistema operativo o el planificador del SO).
DROP EVENT IF EXISTS ev_diario_backup_simulado$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_backup_simulado
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 3 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
  INSERT INTO alertas (tipo, mensaje, atendida)
  VALUES ('BACKUP_SIMULADO', CONCAT('Respaldo lógico simulado de ecommerce_db: ', NOW()), TRUE)$$

-- 11. ev_diario_limpiar_vistas_antiguas
-- Cada día 03:30: elimina vistas de producto de más de 90 días.
DROP EVENT IF EXISTS ev_diario_limpiar_vistas_antiguas$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_limpiar_vistas_antiguas
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 210 MINUTE)
ON COMPLETION PRESERVE ENABLE
DO
  DELETE FROM vistas_producto WHERE fecha_vista < DATE_SUB(NOW(), INTERVAL 90 DAY)$$

-- 12. ev_diario_depurar_carritos_abandonados
-- Cada día 04:00: borra carritos abandonados de más de 60 días (sus ítems caen en cascada).
DROP EVENT IF EXISTS ev_diario_depurar_carritos_abandonados$$
CREATE DEFINER='root'@'localhost' EVENT ev_diario_depurar_carritos_abandonados
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 4 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
  DELETE FROM carritos
   WHERE estado = 'Abandonado' AND fecha_actualizacion < DATE_SUB(NOW(), INTERVAL 60 DAY)$$

-- ===================== SEMANALES =====================

-- 13. ev_semanal_reporte_ventas
-- Cada semana: consolida la semana anterior (lunes a domingo) en reporte_ventas_semanales.
DROP EVENT IF EXISTS ev_semanal_reporte_ventas$$
CREATE DEFINER='root'@'localhost' EVENT ev_semanal_reporte_ventas
ON SCHEDULE EVERY 1 WEEK STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 5 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
  REPLACE INTO reporte_ventas_semanales
         (anio_semana, fecha_inicio, fecha_fin, num_ventas, ingresos, ticket_promedio)
  SELECT YEARWEEK(DATE_SUB(CURRENT_DATE, INTERVAL 7 DAY), 3),
         DATE_SUB(CURRENT_DATE, INTERVAL WEEKDAY(CURRENT_DATE) + 7 DAY),
         DATE_SUB(CURRENT_DATE, INTERVAL WEEKDAY(CURRENT_DATE) + 1 DAY),
         COUNT(*), COALESCE(SUM(total), 0), COALESCE(ROUND(AVG(total), 2), 0)
    FROM ventas
   WHERE estado IN ('Pagado','Enviado','Entregado')
     AND fecha_venta >= DATE_SUB(CURRENT_DATE, INTERVAL WEEKDAY(CURRENT_DATE) + 7 DAY)
     AND fecha_venta <  DATE_SUB(CURRENT_DATE, INTERVAL WEEKDAY(CURRENT_DATE) DAY)$$

-- 14. ev_semanal_reporte_proveedores
-- Cada semana: valor de inventario por proveedor.
DROP EVENT IF EXISTS ev_semanal_reporte_proveedores$$
CREATE DEFINER='root'@'localhost' EVENT ev_semanal_reporte_proveedores
ON SCHEDULE EVERY 1 WEEK STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 5 HOUR + INTERVAL 30 MINUTE)
ON COMPLETION PRESERVE ENABLE
DO CALL sp_GenerarReporteProveedores()$$

-- 15. ev_semanal_archivar_ventas_antiguas
-- Cada semana: copia a ventas_archivo las ventas cerradas de más de 12 meses.
-- Solo copia (no borra): borrar ventas rompería la trazabilidad y el trigger 10 bloquea líneas.
DROP EVENT IF EXISTS ev_semanal_archivar_ventas_antiguas$$
CREATE DEFINER='root'@'localhost' EVENT ev_semanal_archivar_ventas_antiguas
ON SCHEDULE EVERY 1 WEEK STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 6 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
BEGIN
  DECLARE v_filas INT DEFAULT 0;
  CALL sp_ArchivarVentasAntiguas(12, v_filas);
END$$

-- 16. ev_semanal_optimizar_tablas_simulado
-- SIMULACIÓN: registra la ventana de mantenimiento. El OPTIMIZE/ANALYZE real conviene
-- ejecutarlo manualmente en horario de baja carga.
DROP EVENT IF EXISTS ev_semanal_optimizar_tablas_simulado$$
CREATE DEFINER='root'@'localhost' EVENT ev_semanal_optimizar_tablas_simulado
ON SCHEDULE EVERY 1 WEEK STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 7 HOUR)
ON COMPLETION PRESERVE ENABLE
DO
  INSERT INTO alertas (tipo, mensaje, atendida)
  VALUES ('MANTENIMIENTO_SIMULADO', CONCAT('Ventana de optimización simulada: ', NOW()), TRUE)$$

-- ===================== MENSUALES =====================

-- 17. ev_mensual_kpis
-- El día 1 de cada mes: calcula los KPIs del mes anterior.
DROP EVENT IF EXISTS ev_mensual_kpis$$
CREATE DEFINER='root'@'localhost' EVENT ev_mensual_kpis
ON SCHEDULE EVERY 1 MONTH
  STARTS TIMESTAMP(DATE_FORMAT(DATE_ADD(CURRENT_DATE, INTERVAL 1 MONTH), '%Y-%m-01'), '04:00:00')
ON COMPLETION PRESERVE ENABLE
DO
  CALL sp_CalcularKPIsMensuales(YEAR(DATE_SUB(CURRENT_DATE, INTERVAL 1 MONTH)),
                                MONTH(DATE_SUB(CURRENT_DATE, INTERVAL 1 MONTH)))$$

-- 18. ev_mensual_reconciliar_total_gastado
-- El día 1 de cada mes: recalcula agregados derivados desde la fuente de verdad ventas.
DROP EVENT IF EXISTS ev_mensual_reconciliar_total_gastado$$
CREATE DEFINER='root'@'localhost' EVENT ev_mensual_reconciliar_total_gastado
ON SCHEDULE EVERY 1 MONTH
  STARTS TIMESTAMP(DATE_FORMAT(DATE_ADD(CURRENT_DATE, INTERVAL 1 MONTH), '%Y-%m-01'), '04:30:00')
ON COMPLETION PRESERVE ENABLE
DO
BEGIN
  UPDATE clientes c
     SET c.total_gastado = fn_TotalGastadoCliente(c.id_cliente),
         c.fecha_ultimo_pedido = (
           SELECT MAX(v.fecha_venta)
             FROM ventas v
            WHERE v.id_cliente = c.id_cliente
              AND v.estado IN ('Pagado','Enviado','Entregado')
         );
END$$

-- 19. ev_mensual_purgar_logs_antiguos
-- El día 1 de cada mes: elimina logs de clientes y de estados con más de 24 meses.
DROP EVENT IF EXISTS ev_mensual_purgar_logs_antiguos$$
CREATE DEFINER='root'@'localhost' EVENT ev_mensual_purgar_logs_antiguos
ON SCHEDULE EVERY 1 MONTH
  STARTS TIMESTAMP(DATE_FORMAT(DATE_ADD(CURRENT_DATE, INTERVAL 1 MONTH), '%Y-%m-01'), '05:00:00')
ON COMPLETION PRESERVE ENABLE
DO
BEGIN
  DELETE FROM log_clientes       WHERE fecha < DATE_SUB(NOW(), INTERVAL 24 MONTH);
  DELETE FROM log_estado_pedido  WHERE fecha < DATE_SUB(NOW(), INTERVAL 24 MONTH);
END$$

-- ===================== TRIMESTRAL =====================

-- 20. ev_trimestral_desactivar_clientes_inactivos
-- Cada 3 meses: desactiva clientes sin compras en 12 meses (el trigger 16 lo audita).
DROP EVENT IF EXISTS ev_trimestral_desactivar_clientes_inactivos$$
CREATE DEFINER='root'@'localhost' EVENT ev_trimestral_desactivar_clientes_inactivos
ON SCHEDULE EVERY 3 MONTH
  STARTS TIMESTAMP(DATE_FORMAT(DATE_ADD(CURRENT_DATE, INTERVAL 1 MONTH), '%Y-%m-01'), '05:30:00')
ON COMPLETION PRESERVE ENABLE
DO
  UPDATE clientes
     SET activo = FALSE
   WHERE activo = TRUE
     AND COALESCE(fecha_ultimo_pedido, fecha_registro) < DATE_SUB(NOW(), INTERVAL 12 MONTH)$$

DELIMITER ;
