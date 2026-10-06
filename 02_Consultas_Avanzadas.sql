-- =====================================================================
-- 02_Consultas_Avanzadas.sql
-- 20 consultas analíticas sobre ecommerce_db (MySQL 8.0).
-- Regla global: TODO cálculo de ingresos EXCLUYE ventas con estado 'Cancelado'.
-- A nivel de venta se usa ventas.total (neto, incluido descuento de pedido).
-- Los análisis por producto/categoría basados en líneas representan ingreso bruto de línea;
-- el descuento monetario de pedido no se atribuye a un producto específico.
-- Los "hoy" relativos usan MAX(fecha_venta) para que la semilla siempre devuelva filas.
-- =====================================================================
USE ecommerce_db;

-- 1. Top 10 Productos Más Vendidos
-- Pregunta de negocio: ¿Qué productos generan más unidades e ingresos?
SELECT p.id_producto, p.nombre,
       SUM(d.cantidad) AS unidades_vendidas,
       ROUND(SUM(d.cantidad * d.precio_unitario_congelado), 2) AS ingresos_linea_brutos
  FROM detalle_ventas d
  JOIN ventas v    ON v.id_venta = d.id_venta AND v.estado IN ('Pagado','Enviado','Entregado')
  JOIN productos p ON p.id_producto = d.id_producto
 GROUP BY p.id_producto, p.nombre
 ORDER BY unidades_vendidas DESC, ingresos_linea_brutos DESC
 LIMIT 10;

-- 2. Segmentación de Clientes por Deciles de Gasto (NTILE(10))
-- Pregunta de negocio: ¿Cuánto concentra el 10% de clientes que más gasta?
WITH gasto AS (
  SELECT c.id_cliente, SUM(v.total) AS gastado
    FROM clientes c
    JOIN ventas v ON v.id_cliente = c.id_cliente AND v.estado IN ('Pagado','Enviado','Entregado')
   GROUP BY c.id_cliente
), deciles AS (
  SELECT id_cliente, gastado,
         NTILE(10) OVER (ORDER BY gastado DESC) AS decil
    FROM gasto
)
SELECT decil, COUNT(*) AS clientes,
       ROUND(SUM(gastado), 2) AS gasto_total,
       ROUND(AVG(gastado), 2) AS gasto_promedio,
       ROUND(MIN(gastado), 2) AS gasto_min,
       ROUND(MAX(gastado), 2) AS gasto_max
  FROM deciles
 GROUP BY decil
 ORDER BY decil;

-- 3. Ventas Mensuales y Crecimiento vs. Mes Anterior (LAG)
-- Pregunta de negocio: ¿Cómo evolucionan los ingresos mes a mes?
WITH mensual AS (
  SELECT DATE_FORMAT(fecha_venta, '%Y-%m') AS mes,
         COUNT(*) AS num_ventas, SUM(total) AS ingresos
    FROM ventas
   WHERE estado IN ('Pagado','Enviado','Entregado')
   GROUP BY DATE_FORMAT(fecha_venta, '%Y-%m')
)
SELECT mes, num_ventas, ROUND(ingresos, 2) AS ingresos,
       ROUND(LAG(ingresos) OVER (ORDER BY mes), 2) AS ingresos_mes_anterior,
       ROUND((ingresos / LAG(ingresos) OVER (ORDER BY mes) - 1) * 100, 2) AS crecimiento_pct
  FROM mensual
 ORDER BY mes;

-- 4. Ingresos Acumulados por Mes (SUM() OVER)
-- Pregunta de negocio: ¿Cuál es el ingreso acumulado en el tiempo?
WITH mensual AS (
  SELECT DATE_FORMAT(fecha_venta, '%Y-%m') AS mes, SUM(total) AS ingresos
    FROM ventas
   WHERE estado IN ('Pagado','Enviado','Entregado')
   GROUP BY DATE_FORMAT(fecha_venta, '%Y-%m')
)
SELECT mes, ROUND(ingresos, 2) AS ingresos,
       ROUND(SUM(ingresos) OVER (ORDER BY mes ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS ingresos_acumulados
  FROM mensual
 ORDER BY mes;

-- 5. Ranking de Productos dentro de su Categoría (RANK)
-- Pregunta de negocio: ¿Cuáles son los 3 productos líderes de cada categoría?
WITH ventas_prod AS (
  SELECT p.id_categoria, p.id_producto, p.nombre,
         SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos_linea_brutos
    FROM detalle_ventas d
    JOIN ventas v    ON v.id_venta = d.id_venta AND v.estado IN ('Pagado','Enviado','Entregado')
    JOIN productos p ON p.id_producto = d.id_producto
   GROUP BY p.id_categoria, p.id_producto, p.nombre
), ranking AS (
  SELECT id_categoria, id_producto, nombre, ingresos_linea_brutos,
         RANK() OVER (PARTITION BY id_categoria ORDER BY ingresos_linea_brutos DESC) AS posicion
    FROM ventas_prod
)
SELECT c.nombre AS categoria, r.posicion, r.nombre AS producto, ROUND(r.ingresos_linea_brutos, 2) AS ingresos_linea_brutos
  FROM ranking r
  JOIN categorias c ON c.id_categoria = r.id_categoria
 WHERE r.posicion <= 3
 ORDER BY c.nombre, r.posicion;

-- 6. Productos que Nunca se Han Vendido
-- Pregunta de negocio: ¿Qué inventario no rota y qué capital inmoviliza?
SELECT p.id_producto, p.sku, p.nombre, p.stock,
       ROUND(p.stock * p.costo, 2) AS capital_inmovilizado
  FROM productos p
 WHERE NOT EXISTS (SELECT 1
                     FROM detalle_ventas d
                     JOIN ventas v ON v.id_venta = d.id_venta AND v.estado IN ('Pagado','Enviado','Entregado')
                    WHERE d.id_producto = p.id_producto)
 ORDER BY capital_inmovilizado DESC;

-- 7. Productos Comprados Juntos (auto-join de detalle_ventas)
-- Pregunta de negocio: ¿Qué pares de productos aparecen en la misma venta?
SELECT p1.nombre AS producto_a, p2.nombre AS producto_b, COUNT(*) AS veces_juntos
  FROM detalle_ventas d1
  JOIN detalle_ventas d2 ON d2.id_venta = d1.id_venta AND d1.id_producto < d2.id_producto
  JOIN ventas v          ON v.id_venta = d1.id_venta AND v.estado IN ('Pagado','Enviado','Entregado')
  JOIN productos p1      ON p1.id_producto = d1.id_producto
  JOIN productos p2      ON p2.id_producto = d2.id_producto
 GROUP BY p1.nombre, p2.nombre
 ORDER BY veces_juntos DESC, producto_a, producto_b
 LIMIT 15;

-- 8. Clientes Recurrentes (GROUP BY / HAVING)
-- Pregunta de negocio: ¿Quiénes compraron 5 veces o más y cuánto gastan por compra?
SELECT c.id_cliente, c.nombre, c.ciudad,
       COUNT(*) AS compras,
       ROUND(SUM(v.total), 2) AS gasto_total,
       ROUND(AVG(v.total), 2) AS ticket_promedio,
       MIN(v.fecha_venta) AS primera_compra,
       MAX(v.fecha_venta) AS ultima_compra
  FROM clientes c
  JOIN ventas v ON v.id_cliente = c.id_cliente AND v.estado IN ('Pagado','Enviado','Entregado')
 GROUP BY c.id_cliente, c.nombre, c.ciudad
HAVING COUNT(*) >= 5
 ORDER BY compras DESC, gasto_total DESC;

-- 9. Margen de Ganancia por Categoría
-- Pregunta de negocio: ¿Qué categorías son más rentables (precio cobrado vs. costo actual)?
SELECT c.nombre AS categoria,
       SUM(d.cantidad) AS unidades,
       ROUND(SUM(d.cantidad * d.precio_unitario_congelado), 2) AS ingresos_linea_brutos,
       ROUND(SUM(d.cantidad * p.costo), 2) AS costo_total,
       ROUND(SUM(d.cantidad * (d.precio_unitario_congelado - p.costo)), 2) AS margen_linea_bruto,
       ROUND(100 * SUM(d.cantidad * (d.precio_unitario_congelado - p.costo))
                 / NULLIF(SUM(d.cantidad * d.precio_unitario_congelado),0), 2) AS margen_linea_pct
  FROM detalle_ventas d
  JOIN ventas v     ON v.id_venta = d.id_venta AND v.estado IN ('Pagado','Enviado','Entregado')
  JOIN productos p  ON p.id_producto = d.id_producto
  JOIN categorias c ON c.id_categoria = p.id_categoria
 GROUP BY c.id_categoria, c.nombre
 ORDER BY margen_linea_bruto DESC;

-- 10. Ventas por Ciudad y Región
-- Pregunta de negocio: ¿Dónde están los mercados más fuertes?
SELECT c.region, c.ciudad,
       COUNT(DISTINCT c.id_cliente) AS clientes_activos,
       COUNT(*) AS ventas,
       ROUND(SUM(v.total), 2) AS ingresos,
       ROUND(100 * SUM(v.total) / SUM(SUM(v.total)) OVER (), 2) AS participacion_pct
  FROM ventas v
  JOIN clientes c ON c.id_cliente = v.id_cliente
 WHERE v.estado IN ('Pagado','Enviado','Entregado')
 GROUP BY c.region, c.ciudad
 ORDER BY ingresos DESC;

-- 11. Ventas por Hora del Día y Día de la Semana
-- Pregunta de negocio: ¿En qué franjas conviene reforzar atención o campañas?
SELECT WEEKDAY(fecha_venta) AS dia_semana_0_lun,
       HOUR(fecha_venta) AS hora,
       COUNT(*) AS ventas,
       ROUND(SUM(total), 2) AS ingresos
  FROM ventas
 WHERE estado IN ('Pagado','Enviado','Entregado')
 GROUP BY WEEKDAY(fecha_venta), HOUR(fecha_venta)
 ORDER BY ventas DESC, dia_semana_0_lun, hora
 LIMIT 20;

-- 12. Ticket Promedio y Desempeño por Sucursal
-- Pregunta de negocio: ¿Qué sucursal vende más y con mejor ticket?
SELECT s.nombre AS sucursal, s.ciudad,
       COUNT(*) AS ventas,
       ROUND(SUM(v.total), 2) AS ingresos,
       ROUND(AVG(v.total), 2) AS ticket_promedio,
       RANK() OVER (ORDER BY SUM(v.total) DESC) AS ranking_ingresos
  FROM ventas v
  JOIN sucursales s ON s.id_sucursal = v.id_sucursal
 WHERE v.estado IN ('Pagado','Enviado','Entregado')
 GROUP BY s.id_sucursal, s.nombre, s.ciudad
 ORDER BY ranking_ingresos;

-- 13. Stock Bajo y Cobertura en Días
-- Pregunta de negocio: ¿Qué productos hay que reponer primero según su rotación de 90 días?
WITH rotacion AS (
  SELECT d.id_producto, SUM(d.cantidad) AS unidades_90d
    FROM detalle_ventas d
    JOIN ventas v ON v.id_venta = d.id_venta AND v.estado IN ('Pagado','Enviado','Entregado')
   WHERE v.fecha_venta >= DATE_SUB((SELECT MAX(fecha_venta) FROM ventas), INTERVAL 90 DAY)
   GROUP BY d.id_producto
)
SELECT p.id_producto, p.nombre, p.stock, p.stock_minimo,
       COALESCE(r.unidades_90d, 0) AS unidades_90d,
       ROUND(COALESCE(r.unidades_90d, 0) / 90, 2) AS venta_diaria,
       ROUND(p.stock / NULLIF(r.unidades_90d / 90, 0), 1) AS dias_de_cobertura
  FROM productos p
  LEFT JOIN rotacion r ON r.id_producto = p.id_producto
 WHERE p.stock <= p.stock_minimo
 ORDER BY dias_de_cobertura IS NULL, dias_de_cobertura, p.stock;

-- 14. Efecto de Promociones: Antes / Durante / Después (ventanas de 30 días)
-- Pregunta de negocio: ¿Las promociones elevan las ventas de su categoría?
SELECT pr.codigo, pr.fecha_inicio, pr.fecha_fin,
       ROUND(SUM(CASE WHEN v.fecha_venta >= DATE_SUB(pr.fecha_inicio, INTERVAL 30 DAY)
                       AND v.fecha_venta <  pr.fecha_inicio
                      THEN d.cantidad * d.precio_unitario_congelado ELSE 0 END), 2) AS ingresos_linea_brutos_antes_30d,
       ROUND(SUM(CASE WHEN v.fecha_venta >= pr.fecha_inicio
                       AND v.fecha_venta <  DATE_ADD(pr.fecha_fin, INTERVAL 1 DAY)
                      THEN d.cantidad * d.precio_unitario_congelado ELSE 0 END), 2) AS ingresos_linea_brutos_durante,
       ROUND(SUM(CASE WHEN v.fecha_venta >= DATE_ADD(pr.fecha_fin, INTERVAL 1 DAY)
                       AND v.fecha_venta <  DATE_ADD(pr.fecha_fin, INTERVAL 31 DAY)
                      THEN d.cantidad * d.precio_unitario_congelado ELSE 0 END), 2) AS ingresos_linea_brutos_despues_30d
  FROM promociones pr
  LEFT JOIN productos p       ON pr.id_categoria IS NULL OR p.id_categoria = pr.id_categoria
  LEFT JOIN detalle_ventas d  ON d.id_producto = p.id_producto
  LEFT JOIN ventas v          ON v.id_venta = d.id_venta AND v.estado IN ('Pagado','Enviado','Entregado')
 GROUP BY pr.id_promocion, pr.codigo, pr.fecha_inicio, pr.fecha_fin
 ORDER BY pr.fecha_inicio;

-- 15. Matriz de Retención por Cohorte (mes de primera compra)
-- Pregunta de negocio: ¿Cuántos clientes de cada cohorte vuelven a comprar 1, 2, ... 6 meses después?
WITH primera AS (
  SELECT id_cliente,
         DATE_SUB(DATE(MIN(fecha_venta)), INTERVAL DAYOFMONTH(MIN(fecha_venta)) - 1 DAY) AS cohorte
    FROM ventas
   WHERE estado IN ('Pagado','Enviado','Entregado')
   GROUP BY id_cliente
), actividad AS (
  SELECT DISTINCT id_cliente,
         DATE_SUB(DATE(fecha_venta), INTERVAL DAYOFMONTH(fecha_venta) - 1 DAY) AS mes
    FROM ventas
   WHERE estado IN ('Pagado','Enviado','Entregado')
), cohorte_mes AS (
  SELECT p.cohorte, p.id_cliente,
         PERIOD_DIFF(EXTRACT(YEAR_MONTH FROM a.mes), EXTRACT(YEAR_MONTH FROM p.cohorte)) AS n
    FROM primera p
    JOIN actividad a ON a.id_cliente = p.id_cliente
)
SELECT DATE_FORMAT(cohorte, '%Y-%m') AS cohorte,
       COUNT(DISTINCT CASE WHEN n = 0 THEN id_cliente END) AS m0_clientes,
       COUNT(DISTINCT CASE WHEN n = 1 THEN id_cliente END) AS m1,
       COUNT(DISTINCT CASE WHEN n = 2 THEN id_cliente END) AS m2,
       COUNT(DISTINCT CASE WHEN n = 3 THEN id_cliente END) AS m3,
       COUNT(DISTINCT CASE WHEN n = 4 THEN id_cliente END) AS m4,
       COUNT(DISTINCT CASE WHEN n = 5 THEN id_cliente END) AS m5,
       COUNT(DISTINCT CASE WHEN n = 6 THEN id_cliente END) AS m6,
       ROUND(100 * COUNT(DISTINCT CASE WHEN n = 1 THEN id_cliente END)
                 / COUNT(DISTINCT CASE WHEN n = 0 THEN id_cliente END), 1) AS retencion_m1_pct
  FROM cohorte_mes
 GROUP BY cohorte
 ORDER BY cohorte;

-- 16. Tasa de Cancelación y Devolución Mensual
-- Pregunta de negocio: ¿Hay meses con problemas operativos o de calidad?
-- (Aquí se cuentan TODAS las ventas del mes como denominador, incluidas las canceladas.)
SELECT DATE_FORMAT(fecha_venta, '%Y-%m') AS mes,
       COUNT(*) AS ventas_totales,
       SUM(estado = 'Cancelado') AS canceladas,
       SUM(estado = 'Devuelto') AS devueltas,
       ROUND(100 * SUM(estado = 'Cancelado') / COUNT(*), 2) AS tasa_cancelacion_pct,
       ROUND(100 * SUM(estado = 'Devuelto') / COUNT(*), 2) AS tasa_devolucion_pct
  FROM ventas
 GROUP BY DATE_FORMAT(fecha_venta, '%Y-%m')
 ORDER BY mes;

-- 17. Carritos Abandonados y Valor Potencial
-- Pregunta de negocio: ¿Cuánto dinero se queda en carritos abandonados y de quién?
SELECT ca.id_carrito, cl.nombre AS cliente, ca.fecha_creacion,
       COUNT(*) AS lineas,
       SUM(ci.cantidad) AS unidades,
       ROUND(SUM(ci.cantidad * p.precio), 2) AS valor_potencial
  FROM carritos ca
  JOIN clientes cl      ON cl.id_cliente = ca.id_cliente
  JOIN carrito_items ci ON ci.id_carrito = ca.id_carrito
  JOIN productos p      ON p.id_producto = ci.id_producto
 WHERE ca.estado = 'Abandonado'
 GROUP BY ca.id_carrito, cl.nombre, ca.fecha_creacion
 ORDER BY valor_potencial DESC;

-- 18. Conversión de Vistas a Ventas por Producto
-- Pregunta de negocio: ¿Qué productos se ven mucho pero se compran poco?
WITH vistas AS (
  SELECT id_producto, COUNT(*) AS vistas FROM vistas_producto GROUP BY id_producto
), ventas_p AS (
  SELECT d.id_producto, SUM(d.cantidad) AS unidades
    FROM detalle_ventas d
    JOIN ventas v ON v.id_venta = d.id_venta AND v.estado IN ('Pagado','Enviado','Entregado')
   GROUP BY d.id_producto
)
SELECT p.id_producto, p.nombre,
       COALESCE(vi.vistas, 0) AS vistas,
       COALESCE(vp.unidades, 0) AS unidades_vendidas,
       ROUND(100 * COALESCE(vp.unidades, 0) / NULLIF(vi.vistas, 0), 2) AS unidades_por_100_vistas
  FROM productos p
  LEFT JOIN vistas vi   ON vi.id_producto = p.id_producto
  LEFT JOIN ventas_p vp ON vp.id_producto = p.id_producto
 ORDER BY vistas DESC, unidades_vendidas
 LIMIT 15;

-- 19. Segmentación RFM (Recencia, Frecuencia, Monetario)
-- Pregunta de negocio: ¿Quiénes son los mejores clientes y quiénes están en riesgo?
-- Puntaje 1-5 con NTILE(5); 5 = mejor en cada dimensión.
WITH base AS (
  SELECT c.id_cliente, c.nombre,
         DATEDIFF((SELECT MAX(fecha_venta) FROM ventas), MAX(v.fecha_venta)) AS recencia_dias,
         COUNT(*) AS frecuencia,
         SUM(v.total) AS monetario
    FROM clientes c
    JOIN ventas v ON v.id_cliente = c.id_cliente AND v.estado IN ('Pagado','Enviado','Entregado')
   GROUP BY c.id_cliente, c.nombre
), puntajes AS (
  SELECT id_cliente, nombre, recencia_dias, frecuencia, monetario,
         NTILE(5) OVER (ORDER BY recencia_dias DESC) AS r,
         NTILE(5) OVER (ORDER BY frecuencia ASC)     AS f,
         NTILE(5) OVER (ORDER BY monetario ASC)      AS m
    FROM base
)
SELECT id_cliente, nombre, recencia_dias, frecuencia, ROUND(monetario, 2) AS monetario,
       r, f, m,
       CASE WHEN r >= 4 AND f >= 4 AND m >= 4 THEN 'Campeón'
            WHEN f >= 4 AND m >= 3            THEN 'Leal'
            WHEN r >= 4                       THEN 'Reciente'
            WHEN r <= 2 AND (f >= 3 OR m >= 3) THEN 'En riesgo'
            WHEN r <= 2                       THEN 'Perdido'
            ELSE 'Regular' END AS segmento
  FROM puntajes
 ORDER BY (r + f + m) DESC, monetario DESC;

-- 20. Media Móvil de 3 Meses y Proyección Lineal de Ingresos (3 meses siguientes)
-- Pregunta de negocio: ¿Hacia dónde va el ingreso mensual?
-- Regresión lineal por mínimos cuadrados calculada a mano (MySQL no trae REGR_SLOPE).
-- El último mes de la semilla es parcial, por lo que la tendencia puede subestimarse.
WITH mensual AS (
  SELECT DATE_FORMAT(fecha_venta, '%Y-%m') AS mes, SUM(total) AS ingresos
    FROM ventas
   WHERE estado IN ('Pagado','Enviado','Entregado')
   GROUP BY DATE_FORMAT(fecha_venta, '%Y-%m')
), serie AS (
  SELECT mes, ingresos, ROW_NUMBER() OVER (ORDER BY mes) AS x
    FROM mensual
), sumas AS (
  SELECT COUNT(*) AS n, SUM(x) AS sx, SUM(ingresos) AS sy,
         SUM(x * ingresos) AS sxy, SUM(x * x) AS sxx
    FROM serie
), recta AS (
  SELECT n,
         (n * sxy - sx * sy) / (n * sxx - sx * sx) AS pendiente,
         (sy - ((n * sxy - sx * sy) / (n * sxx - sx * sx)) * sx) / n AS intercepto
    FROM sumas
)
SELECT t.mes, t.tipo, t.ingresos, t.media_movil_3m, t.tendencia_lineal
  FROM (
    SELECT s.mes, 'Real' AS tipo,
           ROUND(s.ingresos, 2) AS ingresos,
           ROUND(AVG(s.ingresos) OVER (ORDER BY s.x ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS media_movil_3m,
           ROUND(r.intercepto + r.pendiente * s.x, 2) AS tendencia_lineal
      FROM serie s CROSS JOIN recta r
    UNION ALL
    SELECT DATE_FORMAT(DATE_ADD(CONCAT((SELECT MAX(mes) FROM serie), '-01'), INTERVAL k.k MONTH), '%Y-%m'),
           'Proyección', NULL, NULL,
           ROUND(r.intercepto + r.pendiente * (r.n + k.k), 2)
      FROM recta r
      CROSS JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3) k
  ) t
 ORDER BY t.mes;
