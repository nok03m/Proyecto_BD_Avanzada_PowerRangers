-- =====================================================================
-- 00_Instalacion.sql - instalador de referencia (mysql client)
-- Ejecutar con una cuenta administradora; los objetos privilegiados quedan con
-- DEFINER='root'@'localhost', por lo que root@localhost debe existir.
-- ADVERTENCIA: 01 recrea ecommerce_db y borra los datos existentes.
-- 04_Seguridad.sql crea cuentas bloqueadas/expiradas; las contraseñas reales
-- se deben provisionar fuera del repositorio.
-- =====================================================================
SOURCE 01_Esquema_y_Datos.sql;
SOURCE 02_Consultas_Avanzadas.sql;
SOURCE 03_Funciones.sql;
SOURCE 05_Triggers.sql;
SOURCE 06_Eventos.sql;
SOURCE 07_Procedimientos_Almacenados.sql;
SOURCE 04_Seguridad.sql;
-- 08_Verificacion_Final.sql es opcional y no modifica datos.
