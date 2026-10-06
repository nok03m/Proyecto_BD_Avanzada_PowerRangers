-- =====================================================================
-- 08_Verificacion_Final.sql
-- Smoke-test posterior a la instalación. No modifica datos.
-- Ejecutar después de 00_Instalacion.sql.
-- Las consultas de integridad deben devolver 0 filas; los conteos de objetos
-- deben coincidir con los valores documentados.
-- =====================================================================
USE ecommerce_db;

-- 1. Conteo de objetos
SELECT COUNT(*) AS funciones_ok
  FROM information_schema.ROUTINES
 WHERE routine_schema = 'ecommerce_db' AND routine_type = 'FUNCTION'; -- 20

SELECT COUNT(*) AS procedimientos_ok
  FROM information_schema.ROUTINES
 WHERE routine_schema = 'ecommerce_db' AND routine_type = 'PROCEDURE'; -- 20

SELECT COUNT(*) AS triggers_ok
  FROM information_schema.TRIGGERS
 WHERE trigger_schema = 'ecommerce_db'; -- 34

SELECT COUNT(*) AS eventos_ok
  FROM information_schema.EVENTS
 WHERE event_schema = 'ecommerce_db'; -- 20

-- 2. Totales de venta: no debe devolver filas
SELECT v.id_venta
  FROM ventas v
  LEFT JOIN detalle_ventas d ON d.id_venta = v.id_venta
 GROUP BY v.id_venta, v.total, v.descuento_total
HAVING v.total <> ROUND(
         GREATEST(COALESCE(SUM(d.cantidad * d.precio_unitario_congelado),0)
                  - v.descuento_total, 0), 2);

-- 3. Envío de ventas integradas: no debe devolver filas
SELECT v.id_venta
  FROM ventas v
 WHERE v.control_stock = 'Integrado'
   AND v.costo_envio <> fn_CostoEnvio(fn_PesoTotalVenta(v.id_venta));

-- 4. Total gastado y última compra: no debe devolver filas
SELECT c.id_cliente
  FROM clientes c
 WHERE ABS(c.total_gastado - fn_TotalGastadoCliente(c.id_cliente)) > 0.01
    OR NOT (c.fecha_ultimo_pedido <=> (
         SELECT MAX(v.fecha_venta)
           FROM ventas v
          WHERE v.id_cliente = c.id_cliente
            AND v.estado IN ('Pagado','Enviado','Entregado')));

-- 5. Integridad de devoluciones: no debe devolver filas
SELECT d.id_devolucion
  FROM devoluciones d
  LEFT JOIN detalle_ventas dv
    ON dv.id_venta = d.id_venta AND dv.id_producto = d.id_producto
 WHERE dv.id_detalle IS NULL;

-- 6. Cantidades devueltas no pueden superar cantidades vendidas: no debe devolver filas
SELECT d.id_venta, d.id_producto
  FROM detalle_ventas d
  JOIN (
      SELECT id_venta, id_producto, SUM(cantidad) AS devuelto
        FROM devoluciones
       WHERE estado = 'Aprobada'
       GROUP BY id_venta, id_producto
  ) r ON r.id_venta = d.id_venta AND r.id_producto = d.id_producto
 WHERE r.devuelto > d.cantidad;

-- 7. Pagos: monto debe coincidir con total + envío: no debe devolver filas
SELECT p.id_pago
  FROM pagos p
  JOIN ventas v ON v.id_venta = p.id_venta
 WHERE p.monto <> ROUND(v.total + v.costo_envio,2);

-- 8. Ventas Canceladas no deben conservar pagos aprobados/reembolsados: no debe devolver filas
SELECT v.id_venta, p.estado
  FROM ventas v
  JOIN pagos p ON p.id_venta = v.id_venta
 WHERE v.estado = 'Cancelado'
   AND p.estado IN ('Aprobado','Reembolsado');

-- 9. Ventas Pagadas/Enviadas/Entregadas/Devueltas necesitan pago aprobable: no debe devolver filas
SELECT v.id_venta, v.estado
  FROM ventas v
  LEFT JOIN pagos p
    ON p.id_venta = v.id_venta AND p.estado IN ('Aprobado','Reembolsado')
 WHERE v.estado IN ('Pagado','Enviado','Entregado','Devuelto')
   AND p.id_pago IS NULL;

-- 10. Stock nunca puede ser negativo: no debe devolver filas
SELECT id_producto, stock
  FROM productos
 WHERE stock < 0;

-- 11. Ventas posteriores a la semilla (>= 2026-09-21) no pueden estar en Historico: no debe devolver filas
-- (las 320 ventas semilla son Historico por diseño)
SELECT id_venta, control_stock
  FROM ventas
 WHERE control_stock <> 'Integrado'
   AND fecha_venta >= '2026-09-21';

-- 12. Comprobación estructural de FK compuesta de devoluciones: debe devolver 1 fila
SELECT COUNT(DISTINCT constraint_name) AS fk_compuesta_devoluciones
  FROM information_schema.KEY_COLUMN_USAGE
 WHERE constraint_schema = 'ecommerce_db'
   AND table_name = 'devoluciones'
   AND constraint_name = 'fk_dev_venta_prod'
   AND referenced_table_name = 'detalle_ventas';
