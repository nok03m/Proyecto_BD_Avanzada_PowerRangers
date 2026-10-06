-- =====================================================================
-- trg_audit_cliente_after_update.sql
-- Auditoría de cambios en datos sensibles de clientes (email y dirección de envío).
-- Script autónomo: crea la tabla de auditoría y el trigger.
-- Requiere la tabla clientes (01_Esquema_y_Datos.sql). Ejecutar después de 05_Triggers.sql.
-- Es re-ejecutable: la tabla usa IF NOT EXISTS y el trigger se recrea.
-- =====================================================================
USE ecommerce_db;

-- ---------------------------------------------------------------------
-- 1. Tabla de auditoría
-- Una fila por cada campo sensible modificado. No tiene FK a clientes a propósito:
-- el historial debe conservarse aunque el cliente se elimine.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS Auditoria_Clientes (
  id_auditoria       INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente         INT NOT NULL,
  campo_modificado   VARCHAR(50) NOT NULL,   -- 'email' o 'direccion_envio'
  valor_antiguo      VARCHAR(200) NULL,
  valor_nuevo        VARCHAR(200) NULL,
  fecha_modificacion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_audcli_cliente (id_cliente, fecha_modificacion)
) ENGINE=InnoDB;

DELIMITER $$

-- ---------------------------------------------------------------------
-- 2. Trigger AFTER UPDATE sobre clientes
-- Lógica:
--  * Se evalúa cada campo por separado con el operador NULL-safe <=>
--    (OLD.x <=> NEW.x es verdadero si son iguales, incluso si ambos son NULL).
--    Así un cambio de NULL a un valor (o al revés) también se audita.
--  * Solo se inserta una fila si el valor de email o de dirección realmente cambió;
--    cualquier otro UPDATE (nombre, ciudad, total_gastado...) no deja rastro aquí.
--  * Si cambian ambos campos en el mismo UPDATE se insertan dos filas.
--  * La columna física de la dirección es clientes.direccion; en la auditoría se
--    registra con el nombre de negocio 'direccion_envio'.
--  * AFTER UPDATE garantiza que el cambio ya pasó las validaciones (BEFORE UPDATE),
--    por lo que el email nuevo auditado ya está normalizado.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_audit_cliente_after_update$$
CREATE DEFINER='root'@'localhost' TRIGGER trg_audit_cliente_after_update
AFTER UPDATE ON clientes FOR EACH ROW
BEGIN
  IF NOT (OLD.email <=> NEW.email) THEN
    INSERT INTO Auditoria_Clientes (id_cliente, campo_modificado, valor_antiguo, valor_nuevo)
    VALUES (NEW.id_cliente, 'email', OLD.email, NEW.email);
  END IF;

  IF NOT (OLD.direccion <=> NEW.direccion) THEN
    INSERT INTO Auditoria_Clientes (id_cliente, campo_modificado, valor_antiguo, valor_nuevo)
    VALUES (NEW.id_cliente, 'direccion_envio', OLD.direccion, NEW.direccion);
  END IF;
END$$

DELIMITER ;
