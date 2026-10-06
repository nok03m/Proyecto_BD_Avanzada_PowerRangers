-- =====================================================================
-- 01_Esquema_y_Datos.sql
-- Proyecto de Base de Datos para un E-commerce (MySQL 8.0)
-- Contiene: esquema, tablas de soporte, vistas base y datos de ejemplo.
-- Constantes del proyecto (documentadas, usadas en funciones/procedimientos):
--   IVA = 19% (precios con IVA incluido) | 1 USD = 4000 COP
--   Envio por peso total: <=1kg 8000 | <=5kg 15000 | <=20kg 30000 | >20kg 50000
-- Se ejecuta primero. Es re-ejecutable: recrea la base completa.
-- =====================================================================

DROP DATABASE IF EXISTS ecommerce_db;
CREATE DATABASE ecommerce_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE ecommerce_db;

SET NAMES utf8mb4;

-- =====================================================================
-- 1. TABLAS BASE (entidades principales y sucursales)
-- =====================================================================

CREATE TABLE sucursales (
  id_sucursal INT AUTO_INCREMENT PRIMARY KEY,
  nombre      VARCHAR(80) NOT NULL UNIQUE,
  ciudad      VARCHAR(60) NOT NULL,
  activo      BOOLEAN NOT NULL DEFAULT TRUE
) ENGINE=InnoDB;

-- Jerarquia de categorias mediante autorreferencia
CREATE TABLE categorias (
  id_categoria       INT AUTO_INCREMENT PRIMARY KEY,
  nombre             VARCHAR(80) NOT NULL UNIQUE,
  descripcion        VARCHAR(255) NULL,
  id_categoria_padre INT NULL,
  CONSTRAINT fk_cat_padre FOREIGN KEY (id_categoria_padre)
    REFERENCES categorias(id_categoria) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE proveedores (
  id_proveedor INT AUTO_INCREMENT PRIMARY KEY,
  nombre       VARCHAR(100) NOT NULL UNIQUE,
  email        VARCHAR(120) NULL,
  telefono     VARCHAR(30) NULL,
  ciudad       VARCHAR(60) NULL,
  activo       BOOLEAN NOT NULL DEFAULT TRUE
) ENGINE=InnoDB;

CREATE TABLE productos (
  id_producto        INT AUTO_INCREMENT PRIMARY KEY,
  sku                VARCHAR(20) NOT NULL UNIQUE,
  nombre             VARCHAR(120) NOT NULL UNIQUE,
  descripcion        VARCHAR(500) NULL,
  precio             DECIMAL(12,2) NOT NULL,
  costo              DECIMAL(12,2) NOT NULL,
  stock              INT NOT NULL DEFAULT 0,
  stock_minimo       INT NOT NULL DEFAULT 5,
  peso               DECIMAL(8,3) NOT NULL DEFAULT 0,      -- kilogramos
  ubicacion          VARCHAR(20) NULL,                      -- pasillo-estante
  activo             BOOLEAN NOT NULL DEFAULT TRUE,
  id_categoria       INT NOT NULL DEFAULT 1,                -- 1 = "General"
  id_proveedor       INT NULL,
  fecha_creacion     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_modificacion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT chk_prod_precio CHECK (precio > 0),
  CONSTRAINT chk_prod_costo  CHECK (costo >= 0),
  CONSTRAINT chk_prod_stock  CHECK (stock >= 0),
  CONSTRAINT chk_prod_stmin  CHECK (stock_minimo >= 0),
  CONSTRAINT chk_prod_peso   CHECK (peso >= 0),
  CONSTRAINT fk_prod_cat FOREIGN KEY (id_categoria)
    REFERENCES categorias(id_categoria) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_prod_prov FOREIGN KEY (id_proveedor)
    REFERENCES proveedores(id_proveedor) ON DELETE SET NULL ON UPDATE CASCADE,
  INDEX idx_prod_activo (activo),
  INDEX idx_prod_stock (stock)
) ENGINE=InnoDB;

CREATE TABLE clientes (
  id_cliente          INT AUTO_INCREMENT PRIMARY KEY,
  nombre              VARCHAR(100) NOT NULL,
  email               VARCHAR(120) NOT NULL UNIQUE,
  password_hash       VARCHAR(255) NOT NULL,                -- hash PHC generado por la aplicación (Argon2id/bcrypt)
  direccion           VARCHAR(200) NULL,
  fecha_nacimiento    DATE NULL,
  ciudad              VARCHAR(60) NULL,
  region              VARCHAR(60) NULL,
  id_sucursal         INT NULL,
  total_gastado       DECIMAL(12,2) NOT NULL DEFAULT 0,
  fecha_ultimo_pedido TIMESTAMP NULL,
  referido_por        INT NULL,
  activo              BOOLEAN NOT NULL DEFAULT TRUE,
  fecha_registro      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_cli_gastado CHECK (total_gastado >= 0),
  CONSTRAINT fk_cli_suc FOREIGN KEY (id_sucursal)
    REFERENCES sucursales(id_sucursal) ON DELETE SET NULL ON UPDATE RESTRICT,
  CONSTRAINT fk_cli_ref FOREIGN KEY (referido_por)
    REFERENCES clientes(id_cliente) ON DELETE SET NULL ON UPDATE CASCADE,
  INDEX idx_cli_ciudad (ciudad),
  INDEX idx_cli_sucursal (id_sucursal)
) ENGINE=InnoDB;

CREATE TABLE ventas (
  id_venta        INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente      INT NOT NULL,
  id_sucursal     INT NOT NULL,
  fecha_venta     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  estado          ENUM('Pendiente','Pagado','Enviado','Entregado','Cancelado','Devuelto')
                  NOT NULL DEFAULT 'Pendiente',
  total           DECIMAL(12,2) NOT NULL DEFAULT 0,
  descuento_total DECIMAL(12,2) NOT NULL DEFAULT 0,
  costo_envio     DECIMAL(12,2) NOT NULL DEFAULT 0,
  control_stock   ENUM('Historico','Integrado') NOT NULL DEFAULT 'Integrado',
  CONSTRAINT chk_ven_total CHECK (total >= 0),
  CONSTRAINT chk_ven_descuento CHECK (descuento_total >= 0),
  CONSTRAINT chk_ven_envio CHECK (costo_envio >= 0),
  CONSTRAINT fk_ven_cli FOREIGN KEY (id_cliente)
    REFERENCES clientes(id_cliente) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_ven_suc FOREIGN KEY (id_sucursal)
    REFERENCES sucursales(id_sucursal) ON DELETE RESTRICT ON UPDATE RESTRICT,
  INDEX idx_ven_fecha (fecha_venta),
  INDEX idx_ven_estado (estado),
  INDEX idx_ven_suc_fecha (id_sucursal, fecha_venta),
  INDEX idx_ven_cli_fecha (id_cliente, fecha_venta)
) ENGINE=InnoDB;

-- Relacion N:M ventas <-> productos
CREATE TABLE detalle_ventas (
  id_detalle                INT AUTO_INCREMENT PRIMARY KEY,
  id_venta                  INT NOT NULL,
  id_producto               INT NOT NULL,
  cantidad                     INT NOT NULL,
  precio_lista_congelado         DECIMAL(12,2) NOT NULL,       -- precio de lista al momento de la venta
  descuento_unitario_congelado   DECIMAL(12,2) NOT NULL DEFAULT 0,
  precio_unitario_congelado      DECIMAL(12,2) NOT NULL,       -- precio final al momento de la venta
  CONSTRAINT chk_det_cant       CHECK (cantidad > 0),
  CONSTRAINT chk_det_lista      CHECK (precio_lista_congelado > 0),
  CONSTRAINT chk_det_descuento  CHECK (descuento_unitario_congelado >= 0 AND descuento_unitario_congelado <= precio_lista_congelado),
  CONSTRAINT chk_det_precio     CHECK (precio_unitario_congelado > 0),
  CONSTRAINT chk_det_precio_consistente CHECK (precio_unitario_congelado + descuento_unitario_congelado = precio_lista_congelado),
  CONSTRAINT uq_det_venta_prod UNIQUE (id_venta, id_producto),
  CONSTRAINT fk_det_venta FOREIGN KEY (id_venta)
    REFERENCES ventas(id_venta) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_det_prod FOREIGN KEY (id_producto)
    REFERENCES productos(id_producto) ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX idx_det_prod (id_producto)
) ENGINE=InnoDB;

-- =====================================================================
-- 2. TABLAS DE SOPORTE
-- =====================================================================

CREATE TABLE promociones (
  id_promocion INT AUTO_INCREMENT PRIMARY KEY,
  codigo       VARCHAR(30) NOT NULL UNIQUE,
  descripcion  VARCHAR(200) NULL,
  tipo         ENUM('Porcentaje','Monto') NOT NULL,
  valor        DECIMAL(12,2) NOT NULL,
  fecha_inicio DATE NOT NULL,
  fecha_fin    DATE NOT NULL,
  id_categoria INT NULL,
  activa       BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT chk_promo_valor CHECK (valor > 0),
  CONSTRAINT chk_promo_porcentaje CHECK (tipo <> 'Porcentaje' OR valor < 100),
  CONSTRAINT chk_promo_fechas CHECK (fecha_fin >= fecha_inicio),
  CONSTRAINT fk_promo_cat FOREIGN KEY (id_categoria)
    REFERENCES categorias(id_categoria) ON DELETE SET NULL ON UPDATE CASCADE,
  INDEX idx_promo_fechas (fecha_inicio, fecha_fin)
) ENGINE=InnoDB;

CREATE TABLE carritos (
  id_carrito          INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente          INT NOT NULL,
  estado              ENUM('Activo','Abandonado','Convertido') NOT NULL DEFAULT 'Activo',
  fecha_creacion      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_car_cli FOREIGN KEY (id_cliente)
    REFERENCES clientes(id_cliente) ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX idx_car_estado_fecha (estado, fecha_actualizacion)
) ENGINE=InnoDB;

CREATE TABLE carrito_items (
  id_carrito  INT NOT NULL,
  id_producto INT NOT NULL,
  cantidad    INT NOT NULL,
  PRIMARY KEY (id_carrito, id_producto),
  CONSTRAINT chk_ci_cant CHECK (cantidad > 0),
  CONSTRAINT fk_ci_car FOREIGN KEY (id_carrito)
    REFERENCES carritos(id_carrito) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_ci_prod FOREIGN KEY (id_producto)
    REFERENCES productos(id_producto) ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX idx_ci_prod (id_producto)
) ENGINE=InnoDB;

CREATE TABLE vistas_producto (
  id_vista    BIGINT AUTO_INCREMENT PRIMARY KEY,
  id_producto INT NOT NULL,
  id_cliente  INT NULL,
  fecha_vista TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_vp_prod FOREIGN KEY (id_producto)
    REFERENCES productos(id_producto) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_vp_cli FOREIGN KEY (id_cliente)
    REFERENCES clientes(id_cliente) ON DELETE SET NULL ON UPDATE CASCADE,
  INDEX idx_vp_prod (id_producto),
  INDEX idx_vp_cli (id_cliente),
  INDEX idx_vp_fecha (fecha_vista)
) ENGINE=InnoDB;

CREATE TABLE resenas_producto (
  id_resena    INT AUTO_INCREMENT PRIMARY KEY,
  id_producto  INT NOT NULL,
  id_cliente   INT NOT NULL,
  calificacion TINYINT NOT NULL,
  comentario   VARCHAR(500) NULL,
  fecha        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_res_cal CHECK (calificacion BETWEEN 1 AND 5),
  CONSTRAINT uq_res_prod_cli UNIQUE (id_producto, id_cliente),
  CONSTRAINT fk_res_prod FOREIGN KEY (id_producto)
    REFERENCES productos(id_producto) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_res_cli FOREIGN KEY (id_cliente)
    REFERENCES clientes(id_cliente) ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX idx_res_cli (id_cliente)
) ENGINE=InnoDB;

CREATE TABLE pagos (
  id_pago    INT AUTO_INCREMENT PRIMARY KEY,
  id_venta   INT NOT NULL,
  monto      DECIMAL(12,2) NOT NULL,
  metodo     ENUM('Tarjeta','PSE','Efectivo','Transferencia') NOT NULL,
  estado              ENUM('Aprobado','Rechazado','Pendiente','Reembolsado') NOT NULL DEFAULT 'Pendiente',
  monto_reembolsado   DECIMAL(12,2) NOT NULL DEFAULT 0,
  referencia          VARCHAR(40) NULL,
  fecha_pago          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_pago_monto CHECK (monto > 0),
  CONSTRAINT chk_pago_reembolso CHECK (monto_reembolsado >= 0 AND monto_reembolsado <= monto),
  CONSTRAINT fk_pago_venta FOREIGN KEY (id_venta)
    REFERENCES ventas(id_venta) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT uq_pago_venta UNIQUE (id_venta),
  INDEX idx_pago_estado (estado)
) ENGINE=InnoDB;

CREATE TABLE devoluciones (
  id_devolucion INT AUTO_INCREMENT PRIMARY KEY,
  id_venta      INT NOT NULL,
  id_producto   INT NOT NULL,
  cantidad      INT NOT NULL,
  motivo        VARCHAR(200) NULL,
  estado        ENUM('Solicitada','Aprobada','Rechazada') NOT NULL DEFAULT 'Solicitada',
  fecha         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_dev_cant CHECK (cantidad > 0),
  CONSTRAINT fk_dev_venta_prod FOREIGN KEY (id_venta, id_producto)
    REFERENCES detalle_ventas(id_venta, id_producto) ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX idx_dev_venta (id_venta),
  INDEX idx_dev_venta_prod_estado (id_venta, id_producto, estado),
  INDEX idx_dev_prod (id_producto)
) ENGINE=InnoDB;

CREATE TABLE ajustes_stock (
  id_ajuste       INT AUTO_INCREMENT PRIMARY KEY,
  id_producto     INT NOT NULL,
  cantidad_ajuste INT NOT NULL,                              -- positivo o negativo
  motivo          VARCHAR(200) NULL,
  usuario         VARCHAR(80) NULL,
  fecha           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_aj_cant CHECK (cantidad_ajuste <> 0),
  CONSTRAINT fk_aj_prod FOREIGN KEY (id_producto)
    REFERENCES productos(id_producto) ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX idx_aj_prod (id_producto)
) ENGINE=InnoDB;

CREATE TABLE alertas (
  id_alerta INT AUTO_INCREMENT PRIMARY KEY,
  tipo      VARCHAR(40) NOT NULL,
  mensaje   VARCHAR(300) NOT NULL,
  atendida  BOOLEAN NOT NULL DEFAULT FALSE,
  fecha     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_alerta_tipo (tipo, atendida)
) ENGINE=InnoDB;

CREATE TABLE Auditoria_Clientes (
  id_auditoria       INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente         INT NOT NULL,
  campo_modificado   VARCHAR(50) NOT NULL,
  valor_antiguo      VARCHAR(200) NULL,
  valor_nuevo        VARCHAR(200) NULL,
  fecha_modificacion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_audcli_cliente (id_cliente, fecha_modificacion)
) ENGINE=InnoDB;

CREATE TABLE log_clientes (
  id_log     INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente INT NULL,
  accion     VARCHAR(30) NOT NULL,
  detalle    VARCHAR(500) NULL,
  usuario    VARCHAR(80) NULL,
  fecha      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_lc_cli (id_cliente)
) ENGINE=InnoDB;

CREATE TABLE log_estado_pedido (
  id_log          INT AUTO_INCREMENT PRIMARY KEY,
  id_venta        INT NOT NULL,
  estado_anterior VARCHAR(20) NULL,
  estado_nuevo    VARCHAR(20) NOT NULL,
  usuario         VARCHAR(80) NULL,
  fecha           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_lep_venta (id_venta)
) ENGINE=InnoDB;

CREATE TABLE log_permisos (
  id_log  INT AUTO_INCREMENT PRIMARY KEY,
  usuario VARCHAR(80) NOT NULL,
  accion  VARCHAR(60) NOT NULL,
  detalle VARCHAR(500) NULL,
  fecha   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_lp_usuario (usuario)
) ENGINE=InnoDB;

-- Archivo historico de ventas (sin FK: debe sobrevivir a borrados)
CREATE TABLE ventas_archivo (
  id_venta        INT PRIMARY KEY,
  id_cliente      INT NOT NULL,
  id_sucursal     INT NOT NULL,
  fecha_venta     TIMESTAMP NOT NULL,
  estado          VARCHAR(20) NOT NULL,
  total           DECIMAL(12,2) NOT NULL,
  descuento_total DECIMAL(12,2) NOT NULL DEFAULT 0,
  costo_envio     DECIMAL(12,2) NOT NULL DEFAULT 0,
  control_stock   ENUM('Historico','Integrado') NOT NULL DEFAULT 'Historico',
  fecha_archivo   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_va_fecha (fecha_venta)
) ENGINE=InnoDB;

CREATE TABLE resumen_ventas_diarias (
  fecha        DATE PRIMARY KEY,
  num_ventas   INT NOT NULL DEFAULT 0,
  unidades     INT NOT NULL DEFAULT 0,
  total_ventas DECIMAL(14,2) NOT NULL DEFAULT 0
) ENGINE=InnoDB;

CREATE TABLE ranking_productos (
  id_producto   INT PRIMARY KEY,
  unidades      INT NOT NULL DEFAULT 0,
  ingresos      DECIMAL(14,2) NOT NULL DEFAULT 0,
  posicion      INT NOT NULL,
  fecha_calculo TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_rp_prod FOREIGN KEY (id_producto)
    REFERENCES productos(id_producto) ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX idx_rp_pos (posicion)
) ENGINE=InnoDB;

CREATE TABLE kpis_mensuales (
  anio_mes         CHAR(7) PRIMARY KEY,                      -- formato YYYY-MM
  ingresos         DECIMAL(14,2) NOT NULL DEFAULT 0,
  num_ventas       INT NOT NULL DEFAULT 0,
  ticket_promedio  DECIMAL(12,2) NOT NULL DEFAULT 0,
  clientes_nuevos  INT NOT NULL DEFAULT 0,
  tasa_cancelacion DECIMAL(5,2) NOT NULL DEFAULT 0,
  fecha_calculo    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE log_tamano_bd (
  id_log    INT AUTO_INCREMENT PRIMARY KEY,
  tamano_mb DECIMAL(12,2) NOT NULL,
  fecha     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE reporte_reabastecimiento (
  id_reporte        INT AUTO_INCREMENT PRIMARY KEY,
  id_producto       INT NOT NULL,
  stock_actual      INT NOT NULL,
  stock_minimo      INT NOT NULL,
  cantidad_sugerida INT NOT NULL,
  fecha             TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_rr_prod FOREIGN KEY (id_producto)
    REFERENCES productos(id_producto) ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX idx_rr_prod (id_producto)
) ENGINE=InnoDB;

CREATE TABLE reporte_proveedores (
  id_reporte       INT AUTO_INCREMENT PRIMARY KEY,
  id_proveedor     INT NOT NULL,
  num_productos    INT NOT NULL,
  valor_inventario DECIMAL(14,2) NOT NULL,
  fecha            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_rpv_prov FOREIGN KEY (id_proveedor)
    REFERENCES proveedores(id_proveedor) ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX idx_rpv_prov (id_proveedor)
) ENGINE=InnoDB;

CREATE TABLE lista_cumpleanos (
  id_lista         INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente       INT NOT NULL,
  nombre           VARCHAR(100) NOT NULL,
  fecha_nacimiento DATE NOT NULL,
  anio             SMALLINT NOT NULL,
  fecha_generacion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_lcu_cli FOREIGN KEY (id_cliente)
    REFERENCES clientes(id_cliente) ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX idx_lcu_anio (anio)
) ENGINE=InnoDB;

-- Mapa usuario -> sucursal, usado por las vistas de acceso por sucursal (04)
CREATE TABLE usuario_sucursal (
  usuario     VARCHAR(32) PRIMARY KEY,
  id_sucursal INT NOT NULL,
  CONSTRAINT fk_us_suc FOREIGN KEY (id_sucursal)
    REFERENCES sucursales(id_sucursal) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- =====================================================================
-- 3. DATOS DE EJEMPLO
-- =====================================================================

INSERT INTO sucursales (nombre, ciudad) VALUES
 ('Sucursal Cúcuta','Cúcuta'),('Sucursal Bogotá','Bogotá'),
 ('Sucursal Medellín','Medellín'),('Sucursal Cali','Cali');

-- id 1 debe ser "General" (DEFAULT de productos.id_categoria)
INSERT INTO categorias (id_categoria, nombre, descripcion, id_categoria_padre) VALUES
 (1,'General','Categoría por defecto',NULL),
 (2,'Electrónica','Dispositivos electrónicos',NULL),
 (3,'Computadores','Portátiles y periféricos',2),
 (4,'Celulares','Teléfonos y accesorios',2),
 (5,'Hogar','Artículos para el hogar',NULL),
 (6,'Cocina','Electrodomésticos y utensilios',5),
 (7,'Deportes','Equipos y ropa deportiva',NULL),
 (8,'Moda','Ropa y accesorios',NULL),
 (9,'Libros','Libros y guías',NULL),
 (10,'Juguetes','Juegos y juguetes',NULL);

INSERT INTO proveedores (nombre, email, telefono, ciudad) VALUES
 ('TecnoImport SAS','ventas@tecnoimport.co','6011000001','Bogotá'),
 ('MóvilesCol Ltda','pedidos@movilescol.co','6041000002','Medellín'),
 ('Textiles del Norte','contacto@textilesnorte.co','6071000003','Cúcuta'),
 ('HogarPlus SAS','info@hogarplus.co','6021000004','Cali'),
 ('CocinaPro Ltda','ventas@cocinapro.co','6051000005','Barranquilla'),
 ('Distribuidora Andina','andina@distandina.co','6076000006','Bucaramanga');

-- 40 productos. Los ids 37-40 nunca se venden; 5, 12, 23, 31 y 38 tienen stock bajo.
INSERT INTO productos (sku, nombre, precio, costo, stock, stock_minimo, peso, id_categoria, id_proveedor) VALUES
 ('ELE-001','Portátil Ultrabook 14"',3200000,2500000,25,5,1.400,3,1),
 ('ELE-002','Portátil Gamer 16"',5800000,4600000,12,4,2.600,3,1),
 ('ELE-003','Smartphone Gama Media',1500000,1100000,60,10,0.200,4,2),
 ('ELE-004','Smartphone Gama Alta',4200000,3400000,30,8,0.250,4,2),
 ('ELE-005','Tablet 10"',1200000,900000,3,6,0.500,2,2),
 ('ELE-006','Audífonos Inalámbricos',280000,170000,80,15,0.150,2,1),
 ('ELE-007','Monitor 27" 4K',1350000,980000,18,5,5.200,3,1),
 ('ELE-008','Teclado Mecánico',320000,200000,45,10,0.900,3,3),
 ('ELE-009','Mouse Ergonómico',150000,85000,70,15,0.200,3,3),
 ('ELE-010','Cargador Rápido 65W',95000,50000,120,20,0.300,4,2),
 ('HOG-001','Aspiradora Robot',1100000,780000,14,4,3.500,5,4),
 ('HOG-002','Lámpara LED de Escritorio',85000,45000,2,8,0.800,5,4),
 ('HOG-003','Juego de Sábanas Queen',180000,100000,50,10,1.200,5,4),
 ('HOG-004','Silla de Oficina',650000,420000,20,5,9.500,5,4),
 ('COC-001','Licuadora 1200W',260000,160000,35,8,3.000,6,5),
 ('COC-002','Freidora de Aire 5L',420000,280000,28,6,4.800,6,5),
 ('COC-003','Cafetera Espresso',890000,610000,16,4,5.500,6,5),
 ('COC-004','Set de Ollas 10 Piezas',540000,350000,22,5,8.000,6,5),
 ('COC-005','Juego de Cuchillos',210000,120000,40,8,1.600,6,5),
 ('DEP-001','Bicicleta de Montaña',1900000,1350000,10,3,14.000,7,6),
 ('DEP-002','Set de Pesas Ajustables',480000,300000,26,6,20.000,7,6),
 ('DEP-003','Tapete de Yoga',95000,50000,90,15,1.100,7,6),
 ('DEP-004','Balón de Fútbol',110000,60000,4,10,0.450,7,6),
 ('DEP-005','Zapatillas de Running',340000,210000,55,10,0.700,7,6),
 ('MOD-001','Chaqueta Impermeable',290000,170000,42,8,0.800,8,3),
 ('MOD-002','Jeans Clásicos',160000,90000,75,15,0.600,8,3),
 ('MOD-003','Camiseta de Algodón',55000,25000,150,30,0.250,8,3),
 ('MOD-004','Mochila Urbana',175000,100000,48,10,0.900,8,3),
 ('MOD-005','Reloj Deportivo',620000,410000,24,5,0.150,8,1),
 ('LIB-001','Novela Bestseller',65000,35000,100,20,0.500,9,6),
 ('LIB-002','Guía de SQL Avanzado',120000,70000,5,10,0.700,9,6),
 ('LIB-003','Atlas Ilustrado',150000,90000,30,6,1.800,9,6),
 ('JUG-001','Bloques de Construcción 500 pzs',190000,110000,38,8,1.500,10,4),
 ('JUG-002','Muñeca Articulada',130000,70000,44,8,0.600,10,4),
 ('JUG-003','Carro a Control Remoto',240000,150000,27,6,1.200,10,4),
 ('JUG-004','Juego de Mesa Familiar',165000,95000,33,6,1.400,10,4),
 ('GEN-001','Bolsa Reutilizable Pack x5',25000,10000,200,40,0.400,1,6),
 ('GEN-002','Tarjeta de Regalo Física',100000,90000,1,5,0.020,1,6),
 ('GEN-003','Kit de Limpieza para Pantallas',35000,15000,60,12,0.300,1,2),
 ('GEN-004','Organizador de Cables',30000,12000,80,15,0.200,1,2);

UPDATE productos
   SET ubicacion = CONCAT('P',LPAD(1 + (id_producto MOD 5),2,'0'),'-E',LPAD(1 + (id_producto MOD 8),2,'0'))
 WHERE id_producto > 0;

-- 60 clientes en 6 ciudades. Los ids 51-60 nunca compran; los 1-10 son los más frecuentes.
INSERT INTO clientes (nombre, email, password_hash, direccion, fecha_nacimiento,
                      ciudad, region, id_sucursal, referido_por, fecha_registro)
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i + 1 FROM n WHERE i < 60)
SELECT CONCAT(ELT(1 + (i MOD 10),'Juan','María','Carlos','Ana','Luis','Laura','Andrés','Camila','Jorge','Paula'),
              ' ',
              ELT(1 + ((i * 3) MOD 10),'Pérez','Gómez','Rodríguez','López','Martínez','García','Ramírez','Torres','Díaz','Vargas')),
       CONCAT('cliente', i, '@correo.com'),
       CASE i
         WHEN 1 THEN '$argon2id$v=19$m=32768,t=2,p=2$uYJSEGedgLZN1qnX9IDP9w$y3vjuNp39TnJeArK8jNMfYAl+rA2hEbMrAPWZ+0tbPs'
         WHEN 2 THEN '$argon2id$v=19$m=32768,t=2,p=2$NNYl1jmcOeWVI6oUVNLh7g$ZzSYcFD1bB1Q+j+gPnWfjQd5ugR+FXpreghKLBSwiL0'
         WHEN 3 THEN '$argon2id$v=19$m=32768,t=2,p=2$HalhDywp0MDEvwxHmrstcQ$/UErRntgk4ByyBFuJ1afbLS6DDfRn/CyfxbaLQJkG7k'
         WHEN 4 THEN '$argon2id$v=19$m=32768,t=2,p=2$ZYUV+2qYs5kaTxaidw0BVg$S/10sPyq6KKJHIsFIcZ58YDPYCA9NzFaqtghSCZHKmE'
         WHEN 5 THEN '$argon2id$v=19$m=32768,t=2,p=2$+9u+L+6g6+3yuyoX06hKXA$hv7EnyOpuu3HyTND7oJxBSWqsW62QcRE17D36vUr6RU'
         WHEN 6 THEN '$argon2id$v=19$m=32768,t=2,p=2$kvzCHCUOAocEMHincSLDQw$2QIduU+zOzzGaWJUuSPcimbxyNMXC7STYieDNKa65G0'
         WHEN 7 THEN '$argon2id$v=19$m=32768,t=2,p=2$cRI2p+yU1r5UQEqEeCY/Wg$GfLD8Da7hVUo4BEPHQeiiXayhccNA4VEYqZnd8PAv3E'
         WHEN 8 THEN '$argon2id$v=19$m=32768,t=2,p=2$6jTv/8/8sDWlnRxVNZI/AQ$LPUUxYXNwQklTEfDNigBZQRexPDCQ0O+9Y+gsb4YdlI'
         WHEN 9 THEN '$argon2id$v=19$m=32768,t=2,p=2$1fmbPaJKMdIxfmWktgjv4w$3Ruyi+rjY0VKtMz2Q2igC/k2CWKSRt2+h1/D+Ev+yB4'
         WHEN 10 THEN '$argon2id$v=19$m=32768,t=2,p=2$6944IFUCcVASWv3eoHnCtA$xz6zuFop+pHPQkpvKaAYVJQIfn1Nmn7rcDgb+928Gl4'
         WHEN 11 THEN '$argon2id$v=19$m=32768,t=2,p=2$YMfDPnliOa/UfMV4GeZaew$0lRfOFTkR5kBYlx72AZ6OijLf6zFOBsxE7mx5DmmM5g'
         WHEN 12 THEN '$argon2id$v=19$m=32768,t=2,p=2$6gD/khYDKhOB2Aw6by5fJw$JOAFPL9opbZ+Q3xU5P1ntJOkY3XTFcyBj0nKle+d/DI'
         WHEN 13 THEN '$argon2id$v=19$m=32768,t=2,p=2$A9v2wv2Hnd57JDqhAtYsMg$Te9Amy++dp5vgSpWtvGD4e1ltcBpP79XmF95nTFRtrE'
         WHEN 14 THEN '$argon2id$v=19$m=32768,t=2,p=2$3XyHbfuR78Ouz6ET8icq1w$1KPL2R7/yXkGDk2JCJqGhg/QxSl2u2Uf2e7cudEkgOk'
         WHEN 15 THEN '$argon2id$v=19$m=32768,t=2,p=2$nxvRPOPG2Sic2JfureTdwQ$6P4RbJxyJ3uvOKNC/oIvZ3mOaxQPgXWg9Lr90wvXofU'
         WHEN 16 THEN '$argon2id$v=19$m=32768,t=2,p=2$0+AHRuoGz7XhQp+SkthWBA$cH7HBxb/F4YyqOtKUD4QhSp/zv3izSTclrrCCCBRgQs'
         WHEN 17 THEN '$argon2id$v=19$m=32768,t=2,p=2$aexrRWVRqzAeE8PETJeNHQ$IGokCnAjMhLcwenU8cnNq8PG62hbLvhLDAq4BB3I9WY'
         WHEN 18 THEN '$argon2id$v=19$m=32768,t=2,p=2$xp/RLU5zSL82dvg7R5j87Q$hBqt7upFIZVgdz9Eas4BpEhCMQAFgEHRP1rmlSUeMqw'
         WHEN 19 THEN '$argon2id$v=19$m=32768,t=2,p=2$geQw8CSJnXCDI+JdLdIXIA$NX+LdRmnUSNrc9ji5f/JCB5vI4b2S4v6u7LBKmeH1s4'
         WHEN 20 THEN '$argon2id$v=19$m=32768,t=2,p=2$edFBAtMhqxqIEZuts7KkGQ$5bJ6Qc5I83zdESuIUXTkwoRgq7nx8lRvc8N9k5bu08Q'
         WHEN 21 THEN '$argon2id$v=19$m=32768,t=2,p=2$Xl+vIFDqgrQvEnPZVUTjYw$tVl0acNX5/tWTlxeNICdTTZ6B3qqoBYiQrQF94ZnPpU'
         WHEN 22 THEN '$argon2id$v=19$m=32768,t=2,p=2$GjXhURP/yrw005tkajdh2Q$lm1uHfWDMGKg+YZtDjfJiNXDuYK9NE8ZtqVUletxxI0'
         WHEN 23 THEN '$argon2id$v=19$m=32768,t=2,p=2$ba5lJ9RnCQVIN8BxKDhsJQ$aU/C3m0vxzfc1+uUOVoFbQhNxXo0vD+YoS4U9ohksZ0'
         WHEN 24 THEN '$argon2id$v=19$m=32768,t=2,p=2$bmYMbIIPAkxEZNaX/3D2dA$1piht6bGTzZX0uN6wKtAQGgzFp4zm1y6cFXbRHfSycA'
         WHEN 25 THEN '$argon2id$v=19$m=32768,t=2,p=2$3XoAJ70uhoPVNWe3eWGR5Q$5l1dQtHQC9rzubz5ri/E2mYvC4TyK6kduC6J8RG20Xs'
         WHEN 26 THEN '$argon2id$v=19$m=32768,t=2,p=2$OJVKnRWfpFpXvIKG6ei1sw$jkuHbDOi/AFcgtp1Bqs13JClGOQKoMaj+gg975xE+fg'
         WHEN 27 THEN '$argon2id$v=19$m=32768,t=2,p=2$tsYPW0kf5O2hrTZyl414gw$D+dESHt1L1u/7Gqfa7QjW8o3+PJX9/aho9GAUei/5hM'
         WHEN 28 THEN '$argon2id$v=19$m=32768,t=2,p=2$WpXUg38cRwK8KU3ujmEsIw$WLf3Cm5wFapxwO+Fb06DqxFX8fJLyQSgfLc5vr7wVps'
         WHEN 29 THEN '$argon2id$v=19$m=32768,t=2,p=2$lZvcG7o3Xw5mDT09pORRsg$lCaHnSlc++RbJrWtDo+h1Am6NTf+v0uBwZwnTbfciG4'
         WHEN 30 THEN '$argon2id$v=19$m=32768,t=2,p=2$bEgIWdhMxRX2Qbelgcr1Ng$KAJvZTuJ5mWaWLMjCMs++9kt+e2hNp9Z20pokXw0M64'
         WHEN 31 THEN '$argon2id$v=19$m=32768,t=2,p=2$tRS5sLGLnitB1LmrF8+DSQ$H5kywiuROiIEpnuAW5yCid9+icl5oaijM/Yf4fmjuEY'
         WHEN 32 THEN '$argon2id$v=19$m=32768,t=2,p=2$ArSEZLWCDMW1RsqyiHH6Gg$rT0NTt5fQkCyidtZ/gWr3zPrOCj/JqbbLhAoVHIeESo'
         WHEN 33 THEN '$argon2id$v=19$m=32768,t=2,p=2$2YOZRGvxJ5+Elzjo5pVGXQ$uwCpAYy4nCb/YYzQ8RQd1mjoCFvYdw+OScxVbWyJvU4'
         WHEN 34 THEN '$argon2id$v=19$m=32768,t=2,p=2$aIyh/wvPoJu06TJ4zA/NAw$dwopZ4JZTaaEGJZ8tkRuJQ1oXTgtdEjpWGYv28Qzuoc'
         WHEN 35 THEN '$argon2id$v=19$m=32768,t=2,p=2$h/ASpCPWU39FWJEAPE9TvQ$DqLwg95x314GSI/1kwGpuM+0QIrdT/3Bw7BYh6jQ1sw'
         WHEN 36 THEN '$argon2id$v=19$m=32768,t=2,p=2$EIn7AQmj67ujGpdG7YKvNA$RQOF+Jg8/U+bkzydWwV+NDiNXzJgMPZLzxAdbz0OE6I'
         WHEN 37 THEN '$argon2id$v=19$m=32768,t=2,p=2$1JuIEyCyhd20ghdeTlkyZw$TbIoUXVJ0EJcD1QVkbITHM47wDs0V7bzfiCUnTTW94g'
         WHEN 38 THEN '$argon2id$v=19$m=32768,t=2,p=2$eXRQRcRGykGK4u+x8QFgkw$ddXk7+Ez801kIbxl+CDnDC+yIdzeMYAgUP/3HrxE3GQ'
         WHEN 39 THEN '$argon2id$v=19$m=32768,t=2,p=2$q4US4D1Y0+zLq++4OW3Scw$BLrye8+BALPTXny04RBmG+IYCsTXpwL5illHaFqj3Fo'
         WHEN 40 THEN '$argon2id$v=19$m=32768,t=2,p=2$1xhnF7XjqIV6BW2GDFB7fg$gTNPoo/lpK56FHO/fdli0SWWRSVaiYTL8BE6HKJBZJ0'
         WHEN 41 THEN '$argon2id$v=19$m=32768,t=2,p=2$YaO0dbYN6Ezh4uOTQNAaLw$0vqTWDSNh0hokVLJBYFNKHblRC8XMQbS/QMuWtdaEfQ'
         WHEN 42 THEN '$argon2id$v=19$m=32768,t=2,p=2$RKWpW9bk922YYxjJbukcKQ$NLF9PFtf23yFMO0BsSoCYRbehttvrRNzgEsR3ZPCIGs'
         WHEN 43 THEN '$argon2id$v=19$m=32768,t=2,p=2$OLENL+PiLqmKeCiUPQ8zBw$XhAWwNe1rOFcRMOAocw7t+utAtiiZFiNYn3NZxI1Ei0'
         WHEN 44 THEN '$argon2id$v=19$m=32768,t=2,p=2$6ZOsHmjp+6ez7ji/kFdr5Q$ryUPDe/g7v0SwKZUPRBshTND3bDlaP9G5ZpB71pA2wU'
         WHEN 45 THEN '$argon2id$v=19$m=32768,t=2,p=2$/xrslCWteHkzkiSBlkmBEA$WAFo1lOE03e5csURyGUj/LnyvRTYL87AUyCfevDOE/o'
         WHEN 46 THEN '$argon2id$v=19$m=32768,t=2,p=2$PqYyuabWg3BYe78wyyhV2w$Hr/AxKBKx5qVlJ5Y2X33pa2TMgYhhrkvkByMVNd+/dM'
         WHEN 47 THEN '$argon2id$v=19$m=32768,t=2,p=2$PoqXNPK1S80UsTzujmqL1w$G8nhpTyPicWKdkzzqj9nG5xSlnqeigjKIg1dqtOZ+rE'
         WHEN 48 THEN '$argon2id$v=19$m=32768,t=2,p=2$7jmHdQam7UmOkxef4hTBbw$Ueo8qgEcQ/7X92wqBq8aKYsxkSBVqWbcQBBM6VV3GZQ'
         WHEN 49 THEN '$argon2id$v=19$m=32768,t=2,p=2$qQXFjgi0gF7asgfYroW8fw$oSX3hx6hsx6HAAVUFLVfXd99OvQAp1tFEuGfua6zug0'
         WHEN 50 THEN '$argon2id$v=19$m=32768,t=2,p=2$vqZkzFRv/im919aTsPbfYg$FgZxuS8uycfi76402VOIHT+aNxZcwgqB1RHB5gZUKsY'
         WHEN 51 THEN '$argon2id$v=19$m=32768,t=2,p=2$8jtRX/44fkutZQM2CdUpWQ$Yb25JUx4YjzQvmkzJf4snJnAMWp6DiZCLqWoNEYNmiM'
         WHEN 52 THEN '$argon2id$v=19$m=32768,t=2,p=2$g64LGrlshGWMl0oAqNK7xg$PrGCKMI+OvNvdBJoSbJPss/lPrrs9R/7Hx1c1QmwsY4'
         WHEN 53 THEN '$argon2id$v=19$m=32768,t=2,p=2$pCoZxNEP7fN2PA+N11odEw$V81NqZzLtqJM1Ijn/wyhrYW8SarwVsZuAUi7JREkcxk'
         WHEN 54 THEN '$argon2id$v=19$m=32768,t=2,p=2$DnV9BsqXBJWKJeRq+ABtPw$p+hGujaIm/AG86RIrvskisTa2jJFTwZtGzdDh6tSwr4'
         WHEN 55 THEN '$argon2id$v=19$m=32768,t=2,p=2$ZvaeYTFbWeWlm8jBtVo2qw$R+mIfOtbc/dJU3NV2I80YAlciJMW2fFlqyAIgbYu2eQ'
         WHEN 56 THEN '$argon2id$v=19$m=32768,t=2,p=2$QGtT72U0quwD1Tezl0Hflw$TGi2tMnlE/POnswFIhJi98DMqE+/sWvOMUaSu4xWdQc'
         WHEN 57 THEN '$argon2id$v=19$m=32768,t=2,p=2$qmdTEBhwCqt1rcmMNwptyg$14yFv9w/EY/NQokIVJI3doqKdkee7Z86zY4Q3SQGLVA'
         WHEN 58 THEN '$argon2id$v=19$m=32768,t=2,p=2$bUJ0Ai4cYwEwmkl2FZ6x3g$ddqP/jisgfKGs32sSmhhDFMeXA7iHY3A63lhAb/CfAk'
         WHEN 59 THEN '$argon2id$v=19$m=32768,t=2,p=2$yScE18JryoRseNarqNJ+AA$LCQ4X49/ePPMoDqw5KaG6R/QcBBLaJl4aToKW11Yxeo'
         WHEN 60 THEN '$argon2id$v=19$m=32768,t=2,p=2$/9VXTLuhecPAQ/vVDb+TtQ$wiVfaah0f7O18io80ZEX0RaSkR3dWZZBEwqnSrHWdTM'
       END,
       CONCAT('Calle ', 10 + i, ' # ', (i MOD 40) + 1, '-', (i MOD 90) + 1),
       DATE_ADD('1965-01-01', INTERVAL ((i * 211) MOD 14000) DAY),
       ELT(1 + (i MOD 6),'Cúcuta','Bogotá','Medellín','Cali','Barranquilla','Bucaramanga'),
       ELT(1 + (i MOD 6),'Norte de Santander','Cundinamarca','Antioquia','Valle del Cauca','Atlántico','Santander'),
       1 + (i MOD 4),
       CASE WHEN i > 10 AND i MOD 5 = 0 THEN 1 + (i MOD 10) ELSE NULL END,
       TIMESTAMP('2025-01-01 09:00:00')
  FROM n;

-- 320 ventas en ~18 meses, a distintas horas y con todos los estados.
-- El total se calcula después, a partir de las líneas.
INSERT INTO ventas (id_cliente, id_sucursal, fecha_venta, estado, total, descuento_total, costo_envio, control_stock)
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i + 1 FROM n WHERE i < 320)
SELECT c.id_cliente,
       c.id_sucursal,
       TIMESTAMP(DATE_SUB('2026-09-20', INTERVAL ((n.i * 37) MOD 540) DAY),
                 MAKETIME(8 + ((n.i * 5) MOD 13), (n.i * 11) MOD 60, (n.i * 13) MOD 60)),
       ELT(1 + (n.i MOD 10),'Entregado','Entregado','Entregado','Entregado','Entregado',
                            'Enviado','Pagado','Pendiente','Cancelado','Devuelto'),
       0, 0, 0, 'Historico'
  FROM n
  JOIN clientes c
    ON c.id_cliente = CASE WHEN n.i MOD 3 = 0 THEN 1 + (n.i MOD 10)
                           ELSE 1 + ((n.i * 7) MOD 50) END
 ORDER BY n.i;

-- Líneas de venta: 1 a 5 por venta, productos 1-36 (37-40 nunca se venden).
-- El precio congelado difiere del precio actual en ventas antiguas (10% y 5% menos).
INSERT INTO detalle_ventas (id_venta, id_producto, cantidad, precio_lista_congelado,
                                descuento_unitario_congelado, precio_unitario_congelado)
SELECT v.id_venta,
       p.id_producto,
       1 + ((v.id_venta + k.k) MOD 4),
       ROUND(p.precio * CASE WHEN v.fecha_venta < '2026-01-01' THEN 0.90
                             WHEN v.fecha_venta < '2026-06-01' THEN 0.95
                             ELSE 1.00 END, 2),
       0,
       ROUND(p.precio * CASE WHEN v.fecha_venta < '2026-01-01' THEN 0.90
                             WHEN v.fecha_venta < '2026-06-01' THEN 0.95
                             ELSE 1.00 END, 2)
  FROM ventas v
  JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3
        UNION ALL SELECT 4 UNION ALL SELECT 5) k
    ON k.k <= 1 + (v.id_venta MOD 5)
  JOIN productos p
    ON p.id_producto = 1 + ((v.id_venta * 3 + k.k * 7) MOD 36);

-- Total = suma de líneas; envío según el peso total (ver tramos en el encabezado)
UPDATE ventas v
  JOIN (SELECT d.id_venta,
               SUM(d.cantidad * d.precio_unitario_congelado) AS total_lineas,
               SUM(d.cantidad * p.peso)                      AS peso_total
          FROM detalle_ventas d
          JOIN productos p ON p.id_producto = d.id_producto
         GROUP BY d.id_venta) t ON t.id_venta = v.id_venta
   SET v.total = t.total_lineas,
       v.costo_envio = CASE WHEN t.peso_total <= 1  THEN 8000
                            WHEN t.peso_total <= 5  THEN 15000
                            WHEN t.peso_total <= 20 THEN 30000
                            ELSE 50000 END;

-- Estadísticas del cliente (se excluyen ventas canceladas del total gastado)
UPDATE clientes c
  JOIN (SELECT id_cliente,
               SUM(CASE WHEN estado IN ('Pagado','Enviado','Entregado') THEN total ELSE 0 END) AS gastado,
               MAX(CASE WHEN estado IN ('Pagado','Enviado','Entregado') THEN fecha_venta END) AS ultimo
          FROM ventas
         GROUP BY id_cliente) t ON t.id_cliente = c.id_cliente
   SET c.total_gastado = t.gastado,
       c.fecha_ultimo_pedido = t.ultimo;

-- Un pago por venta: Pendiente -> Pendiente, Cancelado -> Rechazado, resto -> Aprobado
INSERT INTO pagos (id_venta, monto, metodo, estado, monto_reembolsado, referencia, fecha_pago)
SELECT id_venta,
       total + costo_envio,
       ELT(1 + (id_venta MOD 4),'Tarjeta','PSE','Efectivo','Transferencia'),
       CASE estado WHEN 'Pendiente' THEN 'Pendiente'
                   WHEN 'Cancelado' THEN 'Rechazado'
                   WHEN 'Devuelto' THEN 'Reembolsado'
                   ELSE 'Aprobado' END,
       CASE WHEN estado = 'Devuelto' THEN total + costo_envio ELSE 0 END,
       CONCAT('PAY-', LPAD(id_venta, 6, '0')),
       DATE_ADD(fecha_venta, INTERVAL 5 MINUTE)
  FROM ventas;

-- Devoluciones para las ventas en estado Devuelto
INSERT INTO devoluciones (id_venta, id_producto, cantidad, motivo, estado, fecha)
SELECT d.id_venta, d.id_producto, d.cantidad,
       ELT(1 + (d.id_venta MOD 3),'Producto defectuoso','No cumple expectativas','Error en el pedido'),
       'Aprobada',
       DATE_ADD(v.fecha_venta, INTERVAL 7 DAY)
  FROM detalle_ventas d
  JOIN ventas v ON v.id_venta = d.id_venta
 WHERE v.estado = 'Devuelto';

INSERT INTO promociones (codigo, descripcion, tipo, valor, fecha_inicio, fecha_fin, id_categoria, activa) VALUES
 ('ELEC10','10% en electrónica','Porcentaje',10,'2026-09-01','2026-10-31',2,TRUE),
 ('HOGAR15','15% en hogar','Porcentaje',15,'2026-08-15','2026-09-15',5,FALSE),
 ('ENVIO0','Descuento fijo de 20.000','Monto',20000,'2026-01-01','2026-12-31',NULL,TRUE),
 ('DEPORTE20','20% en deportes','Porcentaje',20,'2026-10-01','2026-10-31',7,TRUE),
 ('LIBROS5','5% en libros','Porcentaje',5,'2025-11-01','2025-11-30',9,FALSE);

INSERT INTO carritos (id_cliente, estado, fecha_creacion)
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i + 1 FROM n WHERE i < 15)
SELECT 1 + ((i * 4) MOD 50),
       ELT(1 + (i MOD 3),'Activo','Abandonado','Convertido'),
       TIMESTAMP(DATE_SUB('2026-09-25', INTERVAL i * 3 DAY), '10:30:00')
  FROM n;

INSERT INTO carrito_items (id_carrito, id_producto, cantidad)
SELECT c.id_carrito,
       1 + ((c.id_carrito * 5 + k.k * 7) MOD 40),
       1 + (c.id_carrito MOD 3)
  FROM carritos c
  JOIN (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3) k
    ON k.k <= 1 + (c.id_carrito MOD 3);

INSERT INTO vistas_producto (id_producto, id_cliente, fecha_vista)
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i + 1 FROM n WHERE i < 240)
SELECT 1 + ((i * 7) MOD 40),
       CASE WHEN i MOD 4 = 0 THEN NULL ELSE 1 + ((i * 11) MOD 60) END,
       TIMESTAMP(DATE_SUB('2026-09-20', INTERVAL ((i * 5) MOD 200) DAY),
                 MAKETIME(i MOD 24, (i * 7) MOD 60, 0))
  FROM n;

INSERT INTO resenas_producto (id_producto, id_cliente, calificacion, comentario, fecha)
SELECT id_producto, id_cliente,
       CASE WHEN seq MOD 7 = 0 THEN 2
            WHEN seq MOD 5 = 0 THEN 3
            WHEN seq MOD 2 = 0 THEN 4
            ELSE 5 END,
       CONCAT('Reseña de ejemplo ', seq),
       DATE_ADD(fecha_venta, INTERVAL 2 DAY)
  FROM (
    SELECT d.id_producto, v.id_cliente, v.fecha_venta,
           ROW_NUMBER() OVER (
             PARTITION BY d.id_producto, v.id_cliente
             ORDER BY v.fecha_venta DESC, v.id_venta DESC
           ) AS rn,
           ROW_NUMBER() OVER (ORDER BY v.id_venta, d.id_producto) AS seq
      FROM detalle_ventas d
      JOIN ventas v ON v.id_venta = d.id_venta
     WHERE v.estado = 'Entregado'
  ) candidatos
 WHERE rn = 1
 ORDER BY seq
 LIMIT 60;

INSERT INTO ajustes_stock (id_producto, cantidad_ajuste, motivo, usuario) VALUES
 (5,-2,'Merma por daño en bodega','inventory_user'),
 (12,-1,'Unidad de exhibición','inventory_user'),
 (23,10,'Reposición manual','inventory_user'),
 (31,-3,'Conteo físico','inventory_user'),
 (38,1,'Corrección de inventario','inventory_user');

-- Sucursal de cada usuario operativo (usada por las vistas de 01 y los permisos de 04)
INSERT INTO usuario_sucursal (usuario, id_sucursal) VALUES
 ('inventory_user',1),('support_user',2),('marketing_user',3);

-- =====================================================================
-- 4. VISTAS BASE
-- =====================================================================

-- Vista sin email, contraseña ni dirección (se concede a Atencion_Cliente en 04)
CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_info_clientes_basica AS
SELECT id_cliente, nombre, ciudad, region, id_sucursal,
       total_gastado, fecha_ultimo_pedido, activo
  FROM clientes;

-- Acceso por sucursal: cada usuario ve solo la sucursal asignada en usuario_sucursal
CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_ventas_sucursal AS
SELECT v.id_venta, v.id_cliente, v.id_sucursal, v.fecha_venta,
       v.estado, v.total, v.descuento_total, v.costo_envio
  FROM ventas v
 WHERE v.id_sucursal = (SELECT us.id_sucursal
                          FROM usuario_sucursal us
                         WHERE us.usuario = SUBSTRING_INDEX(USER(), '@', 1));

CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_clientes_sucursal AS
SELECT c.id_cliente, c.nombre, c.ciudad, c.region, c.id_sucursal,
       c.total_gastado, c.fecha_ultimo_pedido, c.activo
  FROM clientes c
 WHERE c.id_sucursal = (SELECT us.id_sucursal
                          FROM usuario_sucursal us
                         WHERE us.usuario = SUBSTRING_INDEX(USER(), '@', 1));

CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_devoluciones_sucursal AS
SELECT d.id_devolucion, d.id_venta, d.id_producto, d.cantidad, d.motivo, d.estado, d.fecha
  FROM devoluciones d
  JOIN ventas v ON v.id_venta = d.id_venta
 WHERE v.id_sucursal = (SELECT us.id_sucursal
                           FROM usuario_sucursal us
                          WHERE us.usuario = SUBSTRING_INDEX(USER(), '@', 1));

CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_resenas_publicas AS
SELECT r.id_resena, r.id_producto, r.calificacion, r.comentario, r.fecha
  FROM resenas_producto r;

CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_comportamiento_marketing AS
SELECT vp.id_producto, DATE(vp.fecha_vista) AS dia,
       COUNT(*) AS vistas,
       COUNT(DISTINCT vp.id_cliente) AS visitantes_identificados
  FROM vistas_producto vp
 GROUP BY vp.id_producto, DATE(vp.fecha_vista);

-- Vistas de explotación analítica sin PII sensible ni credenciales.
CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_ventas_analista AS
SELECT v.id_venta, v.id_sucursal, v.fecha_venta, v.estado,
       v.total, v.descuento_total, v.costo_envio
  FROM ventas v;

CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_detalle_ventas_analista AS
SELECT d.id_venta, d.id_producto, d.cantidad,
       d.precio_lista_congelado, d.descuento_unitario_congelado,
       d.precio_unitario_congelado
  FROM detalle_ventas d;

CREATE OR REPLACE DEFINER='root'@'localhost' SQL SECURITY DEFINER VIEW v_clientes_analista AS
SELECT c.id_cliente, c.ciudad, c.region, c.id_sucursal,
       c.total_gastado, c.fecha_ultimo_pedido, c.activo, c.fecha_registro
  FROM clientes c;

-- =====================================================================
-- 5. VERIFICACION (comentada): conteo de filas por tabla
-- =====================================================================
-- SELECT 'sucursales' AS tabla, COUNT(*) AS filas FROM sucursales
-- UNION ALL SELECT 'categorias', COUNT(*) FROM categorias
-- UNION ALL SELECT 'proveedores', COUNT(*) FROM proveedores
-- UNION ALL SELECT 'productos', COUNT(*) FROM productos
-- UNION ALL SELECT 'clientes', COUNT(*) FROM clientes
-- UNION ALL SELECT 'ventas', COUNT(*) FROM ventas
-- UNION ALL SELECT 'detalle_ventas', COUNT(*) FROM detalle_ventas
-- UNION ALL SELECT 'promociones', COUNT(*) FROM promociones
-- UNION ALL SELECT 'carritos', COUNT(*) FROM carritos
-- UNION ALL SELECT 'carrito_items', COUNT(*) FROM carrito_items
-- UNION ALL SELECT 'vistas_producto', COUNT(*) FROM vistas_producto
-- UNION ALL SELECT 'resenas_producto', COUNT(*) FROM resenas_producto
-- UNION ALL SELECT 'pagos', COUNT(*) FROM pagos
-- UNION ALL SELECT 'devoluciones', COUNT(*) FROM devoluciones
-- UNION ALL SELECT 'ajustes_stock', COUNT(*) FROM ajustes_stock
-- UNION ALL SELECT 'alertas', COUNT(*) FROM alertas
-- UNION ALL SELECT 'log_clientes', COUNT(*) FROM log_clientes
-- UNION ALL SELECT 'log_estado_pedido', COUNT(*) FROM log_estado_pedido
-- UNION ALL SELECT 'log_permisos', COUNT(*) FROM log_permisos
-- UNION ALL SELECT 'ventas_archivo', COUNT(*) FROM ventas_archivo
-- UNION ALL SELECT 'resumen_ventas_diarias', COUNT(*) FROM resumen_ventas_diarias
-- UNION ALL SELECT 'ranking_productos', COUNT(*) FROM ranking_productos
-- UNION ALL SELECT 'kpis_mensuales', COUNT(*) FROM kpis_mensuales
-- UNION ALL SELECT 'log_tamano_bd', COUNT(*) FROM log_tamano_bd
-- UNION ALL SELECT 'reporte_reabastecimiento', COUNT(*) FROM reporte_reabastecimiento
-- UNION ALL SELECT 'reporte_proveedores', COUNT(*) FROM reporte_proveedores
-- UNION ALL SELECT 'lista_cumpleanos', COUNT(*) FROM lista_cumpleanos
-- UNION ALL SELECT 'usuario_sucursal', COUNT(*) FROM usuario_sucursal;
--
-- Consistencia: debe devolver 0 filas
-- SELECT v.id_venta FROM ventas v
--   JOIN detalle_ventas d ON d.id_venta = v.id_venta
--  GROUP BY v.id_venta, v.total
-- HAVING v.total <> SUM(d.cantidad * d.precio_unitario_congelado);
