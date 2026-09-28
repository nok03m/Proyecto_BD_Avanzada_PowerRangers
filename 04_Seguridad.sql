-- =====================================================================
-- 04_Seguridad.sql
-- 20 requisitos de seguridad. SE EJECUTA AL FINAL (orden 01,02,03,05,06,07,04):
-- los GRANT necesitan que ya existan log_cambios_precio (05), los procedimientos y
-- funciones (03/07) y las vistas (01).
-- Ejecutar como un administrador conectado por localhost (ver requisito 3).
-- Principio de mínimo privilegio: cada rol recibe solo lo que necesita.
-- Las contraseñas de este archivo son PLACEHOLDERS: las cuentas nacen con la contraseña
-- expirada y deben cambiarla en el primer inicio de sesión. MySQL guarda solo el hash.
-- Requisitos que dependen de la configuración del servidor están marcados con [SERVIDOR].
-- =====================================================================
USE ecommerce_db;

-- ---------------------------------------------------------------------
-- 1. [SERVIDOR] Política de contraseñas: componente validate_password
-- Instala el componente si falta y fija política MEDIUM con longitud mínima 12.
-- Si su versión no admite INSTALL COMPONENT como sentencia preparada, ejecute la
-- línea INSTALL COMPONENT manualmente una sola vez y vuelva a correr este archivo.
-- ---------------------------------------------------------------------
SET @vp_instalado := (SELECT COUNT(*) FROM mysql.component
                       WHERE component_urn = 'file://component_validate_password');
SET @sql := IF(@vp_instalado = 0, 'INSTALL COMPONENT ''file://component_validate_password''', 'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @vp_activo := (SELECT COUNT(*) FROM performance_schema.global_variables
                    WHERE VARIABLE_NAME = 'validate_password.policy');
SET @sql := IF(@vp_activo = 1, 'SET PERSIST validate_password.policy = ''MEDIUM''', 'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
SET @sql := IF(@vp_activo = 1, 'SET PERSIST validate_password.length = 12', 'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ---------------------------------------------------------------------
-- 2. [SERVIDOR] Vigencia e historial de contraseñas (valores globales por defecto)
-- Vencen a los 180 días; no se reutilizan las últimas 5 ni las de los últimos 365 días.
-- ---------------------------------------------------------------------
SET PERSIST default_password_lifetime = 180;
SET PERSIST password_history = 5;
SET PERSIST password_reuse_interval = 365;

-- ---------------------------------------------------------------------
-- 3. Restringir 'root' a localhost
-- Elimina cuentas root remotas. No lo ejecute conectado como root@'%' (perdería el acceso
-- en la próxima conexión); use root@localhost.
-- ---------------------------------------------------------------------
DROP USER IF EXISTS 'root'@'%';

-- ---------------------------------------------------------------------
-- 4. Crear los 7 roles (re-ejecutable: primero se borran usuarios y luego roles)
-- ---------------------------------------------------------------------
DROP USER IF EXISTS 'admin_user'@'localhost';
DROP USER IF EXISTS 'marketing_user'@'localhost';
DROP USER IF EXISTS 'inventory_user'@'localhost';
DROP USER IF EXISTS 'support_user'@'localhost';
DROP USER IF EXISTS 'analyst_user'@'localhost';

DROP ROLE IF EXISTS 'Administrador_Sistema', 'Gerente_Marketing', 'Analista_Datos',
                    'Empleado_Inventario', 'Atencion_Cliente', 'Auditor_Financiero', 'Visitante';
CREATE ROLE 'Administrador_Sistema', 'Gerente_Marketing', 'Analista_Datos',
            'Empleado_Inventario', 'Atencion_Cliente', 'Auditor_Financiero', 'Visitante';

-- ---------------------------------------------------------------------
-- 5. Crear usuarios: admin_user, marketing_user, inventory_user, support_user
-- (+ analyst_user, cuenta adicional necesaria porque los límites de consultas son por cuenta).
-- Contraseña expirada de inmediato, 5 intentos fallidos => bloqueo de 1 día.
-- ---------------------------------------------------------------------
CREATE USER 'admin_user'@'localhost' IDENTIFIED BY 'Cambiar#Admin2026!'
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 PASSWORD EXPIRE;
CREATE USER 'marketing_user'@'localhost' IDENTIFIED BY 'Cambiar#Market2026!'
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 PASSWORD EXPIRE;
CREATE USER 'inventory_user'@'localhost' IDENTIFIED BY 'Cambiar#Invent2026!'
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 PASSWORD EXPIRE;
CREATE USER 'support_user'@'localhost' IDENTIFIED BY 'Cambiar#Soporte2026!'
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 PASSWORD EXPIRE;
CREATE USER 'analyst_user'@'localhost' IDENTIFIED BY 'Cambiar#Analisis2026!'
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 PASSWORD EXPIRE;

-- ---------------------------------------------------------------------
-- 6. Administrador_Sistema: control total sobre la base (sin WITH GRANT OPTION)
-- ---------------------------------------------------------------------
GRANT ALL PRIVILEGES ON ecommerce_db.* TO 'Administrador_Sistema';

-- ---------------------------------------------------------------------
-- 7. Gerente_Marketing: catálogo, promociones, comportamiento y KPIs; sin datos personales
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.productos            TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.categorias           TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.resenas_producto     TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.vistas_producto      TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.carritos             TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.carrito_items        TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.ranking_productos    TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.kpis_mensuales       TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.resumen_ventas_diarias TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.v_info_clientes_basica TO 'Gerente_Marketing';
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.promociones TO 'Gerente_Marketing';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_CrearPromocion TO 'Gerente_Marketing';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_TopClientes    TO 'Gerente_Marketing';

-- ---------------------------------------------------------------------
-- 8. Analista_Datos: solo lectura. No recibe DELETE, TRUNCATE (DROP), INSERT ni UPDATE.
-- En clientes solo columnas no sensibles (sin email, password_hash ni direccion).
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.ventas                  TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.detalle_ventas          TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.productos               TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.categorias              TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.proveedores             TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.sucursales              TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.promociones             TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.carritos                TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.carrito_items           TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.vistas_producto         TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.resenas_producto        TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.pagos                   TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.devoluciones            TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.resumen_ventas_diarias  TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.ranking_productos       TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.kpis_mensuales          TO 'Analista_Datos';
GRANT SELECT (id_cliente, nombre, fecha_nacimiento, ciudad, region, id_sucursal,
              total_gastado, fecha_ultimo_pedido, referido_por, activo, fecha_registro)
  ON ecommerce_db.clientes TO 'Analista_Datos';

-- ---------------------------------------------------------------------
-- 9. Empleado_Inventario: lectura de inventario y ajuste controlado por procedimiento
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.productos                 TO 'Empleado_Inventario';
GRANT SELECT ON ecommerce_db.categorias                TO 'Empleado_Inventario';
GRANT SELECT ON ecommerce_db.proveedores               TO 'Empleado_Inventario';
GRANT SELECT ON ecommerce_db.ajustes_stock             TO 'Empleado_Inventario';
GRANT SELECT ON ecommerce_db.reporte_reabastecimiento  TO 'Empleado_Inventario';
GRANT SELECT ON ecommerce_db.alertas                   TO 'Empleado_Inventario';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_AjustarStock TO 'Empleado_Inventario';

-- ---------------------------------------------------------------------
-- 10. Permiso a nivel de columna: Empleado_Inventario solo puede modificar stock y ubicacion.
-- No tiene UPDATE sobre precio, costo ni ninguna otra columna de productos.
-- ---------------------------------------------------------------------
GRANT UPDATE (stock, ubicacion) ON ecommerce_db.productos TO 'Empleado_Inventario';

-- ---------------------------------------------------------------------
-- 11. Atencion_Cliente: vista de clientes SIN email, contraseña ni dirección, y
--     operaciones de servicio mediante procedimientos (no accede a la tabla clientes).
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.v_info_clientes_basica TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.devoluciones           TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_ObtenerHistorialCliente TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_ActualizarEstadoPedido  TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_CancelarPedido          TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_ProcesarDevolucion      TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_RealizarNuevaVenta      TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_ProcesarPago            TO 'Atencion_Cliente';

-- ---------------------------------------------------------------------
-- 12. Auditor_Financiero: solo lectura de información financiera y de bitácoras
-- (incluye log_cambios_precio, creada en 05; por eso este archivo corre después).
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.ventas                 TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.detalle_ventas         TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.pagos                  TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.devoluciones           TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.ventas_archivo         TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.kpis_mensuales         TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.resumen_ventas_diarias TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.ajustes_stock          TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_cambios_precio     TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_estado_pedido      TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_permisos           TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_clientes           TO 'Auditor_Financiero';
GRANT SELECT (id_producto, sku, nombre, precio, costo, stock, id_categoria, id_proveedor, activo)
  ON ecommerce_db.productos TO 'Auditor_Financiero';

-- ---------------------------------------------------------------------
-- 13. Visitante: solo catálogo público (columnas seleccionadas y productos, sin costos)
-- ---------------------------------------------------------------------
GRANT SELECT (id_producto, nombre, descripcion, precio, id_categoria, activo)
  ON ecommerce_db.productos TO 'Visitante';
GRANT SELECT ON ecommerce_db.categorias       TO 'Visitante';
GRANT SELECT ON ecommerce_db.resenas_producto TO 'Visitante';

-- ---------------------------------------------------------------------
-- 14. Asignar roles a los usuarios y fijar el rol por defecto
-- ---------------------------------------------------------------------
GRANT 'Administrador_Sistema' TO 'admin_user'@'localhost';
GRANT 'Gerente_Marketing'     TO 'marketing_user'@'localhost';
GRANT 'Empleado_Inventario'   TO 'inventory_user'@'localhost';
GRANT 'Atencion_Cliente'      TO 'support_user'@'localhost';
GRANT 'Analista_Datos'        TO 'analyst_user'@'localhost';
SET DEFAULT ROLE 'Administrador_Sistema' TO 'admin_user'@'localhost';
SET DEFAULT ROLE 'Gerente_Marketing'     TO 'marketing_user'@'localhost';
SET DEFAULT ROLE 'Empleado_Inventario'   TO 'inventory_user'@'localhost';
SET DEFAULT ROLE 'Atencion_Cliente'      TO 'support_user'@'localhost';
SET DEFAULT ROLE 'Analista_Datos'        TO 'analyst_user'@'localhost';

-- ---------------------------------------------------------------------
-- 15. Analista_Datos con límite de consultas: MAX_QUERIES_PER_HOUR
-- Los límites de recursos son por cuenta (no por rol), por eso se aplican a analyst_user.
-- Sin UPDATE/DELETE por privilegios (requisito 8); aquí solo se acota el volumen.
-- ---------------------------------------------------------------------
ALTER USER 'analyst_user'@'localhost'
  WITH MAX_QUERIES_PER_HOUR 500 MAX_CONNECTIONS_PER_HOUR 60 MAX_USER_CONNECTIONS 3;

-- ---------------------------------------------------------------------
-- 16. Acceso por sucursal (seguridad a nivel de fila mediante vistas)
-- Las vistas v_ventas_sucursal y v_clientes_sucursal (creadas en 01) filtran por id_sucursal
-- usando la tabla usuario_sucursal y USER(). MySQL no tiene RLS nativo; alternativa:
-- una variable de sesión (@id_sucursal_actual) validada por el aplicativo.
-- Los roles operativos ven solo su sucursal; no reciben acceso a las tablas base de ventas.
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.v_ventas_sucursal   TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.v_clientes_sucursal TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.v_ventas_sucursal   TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.v_clientes_sucursal TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.v_ventas_sucursal   TO 'Empleado_Inventario';

-- ---------------------------------------------------------------------
-- 17. [SERVIDOR] Auditoría de inicios de sesión fallidos
-- (a) Bloqueo temporal de cuentas tras 5 fallos: ya aplicado en el requisito 5.
-- (b) Alternativa sin plugins (Community): intentos fallidos por host desde performance_schema.
--     SELECT ip, host, count_authentication_errors FROM performance_schema.host_cache
--      WHERE count_authentication_errors > 0;
-- (c) Con MySQL Enterprise Edition: plugin/componente de auditoría (requiere licencia y archivo .so):
--     INSTALL PLUGIN audit_log SONAME 'audit_log.so';
--     -- registra conexiones, incluidas las fallidas, en el archivo audit.log
-- (d) Con Community: plugin CONNECTION_CONTROL (retrasa intentos y expone los fallidos):
--     INSTALL PLUGIN CONNECTION_CONTROL SONAME 'connection_control.so';
--     INSTALL PLUGIN CONNECTION_CONTROL_FAILED_LOGIN_ATTEMPTS SONAME 'connection_control.so';
--     SELECT * FROM information_schema.CONNECTION_CONTROL_FAILED_LOGIN_ATTEMPTS;
-- LIMITACIÓN: sin (c) ni (d) no queda un historial persistente por intento; se documenta.
-- ---------------------------------------------------------------------
INSERT INTO log_permisos (usuario, accion, detalle)
VALUES (CURRENT_USER(), 'AUDITORIA_LOGIN', 'Bloqueo tras 5 fallos activo; auditoria completa requiere audit_log (Enterprise) o CONNECTION_CONTROL');

-- ---------------------------------------------------------------------
-- 18. Permisos de EXECUTE sobre funciones (solo las de consulta que cada rol necesita)
-- Las rutinas se ejecutan con los privilegios de su definidor (SQL SECURITY DEFINER por
-- defecto), por lo que basta EXECUTE; el rol no necesita acceso a las tablas internas.
-- ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_CalcularTotalVenta   TO 'Analista_Datos';
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_MargenProducto       TO 'Analista_Datos';
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_NivelCliente         TO 'Analista_Datos';
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_CalcularTotalVenta   TO 'Auditor_Financiero';
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_CalcularIVA          TO 'Auditor_Financiero';
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_ConvertirCOPaUSD     TO 'Auditor_Financiero';
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_StockDisponible      TO 'Empleado_Inventario';
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_EsStockBajo          TO 'Empleado_Inventario';
GRANT EXECUTE ON FUNCTION ecommerce_db.fn_DiasParaAgotar       TO 'Empleado_Inventario';

-- ---------------------------------------------------------------------
-- 19. Registro de la configuración de seguridad aplicada (bitácora log_permisos)
-- ---------------------------------------------------------------------
INSERT INTO log_permisos (usuario, accion, detalle) VALUES
 (CURRENT_USER(), 'CREAR_ROLES',    '7 roles creados'),
 (CURRENT_USER(), 'CREAR_USUARIOS', 'admin_user, marketing_user, inventory_user, support_user, analyst_user'),
 (CURRENT_USER(), 'GRANTS',         'Permisos por rol aplicados; UPDATE(stock, ubicacion) solo para Empleado_Inventario'),
 (CURRENT_USER(), 'ROOT_LOCAL',     'Cuenta root@% eliminada; root restringido a localhost');

-- ---------------------------------------------------------------------
-- 20. Verificación de privilegios efectivos
-- ---------------------------------------------------------------------
FLUSH PRIVILEGES;
SELECT user, host FROM mysql.user WHERE user = 'root';
SHOW GRANTS FOR 'admin_user'@'localhost'     USING 'Administrador_Sistema';
SHOW GRANTS FOR 'marketing_user'@'localhost' USING 'Gerente_Marketing';
SHOW GRANTS FOR 'inventory_user'@'localhost' USING 'Empleado_Inventario';
SHOW GRANTS FOR 'support_user'@'localhost'   USING 'Atencion_Cliente';
SHOW GRANTS FOR 'analyst_user'@'localhost'   USING 'Analista_Datos';
