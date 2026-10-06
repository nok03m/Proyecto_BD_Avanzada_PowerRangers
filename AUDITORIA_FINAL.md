# Auditoría final — Proyecto_BD_Avanzada_PowerRangers

**Fecha:** 2026-10-05  
**Objetivo:** endurecer el proyecto priorizando integridad de datos, seguridad, buenas prácticas, consistencia transaccional y mantenibilidad.

## Resultado ejecutivo

**Estado: APROBADO — 50/50 verificaciones estáticas superadas.**

La revisión final no reproduce los hallazgos críticos detectados en la auditoría inicial. Las reglas importantes de negocio ahora están protegidas en el esquema mediante claves foráneas, `CHECK`, triggers, estados controlados y procedimientos transaccionales, reduciendo la dependencia de que el usuario llame únicamente a los procedimientos.

> **Limitación de validación:** en el entorno de auditoría no están disponibles `mysql`, `mysqlsh`, `mysqld`, MariaDB ni un driver cliente. Por ello no se ejecutó una instalación real contra un servidor MySQL. El cierre de esta auditoría es **estático/estructural** y debe complementarse con `08_Verificacion_Final.sql` en una instancia MySQL 8.0+.

## Cambios aplicados

### Integridad referencial y modelo

- `devoluciones` ahora referencia `detalle_ventas` con una **FK compuesta** `(id_venta, id_producto)`, impidiendo devoluciones de productos que nunca pertenecieron a la venta.
- La relación `detalle_ventas -> ventas` usa `ON DELETE RESTRICT`; las líneas no desaparecen por cascada.
- `ventas.id_cliente`, `ventas.id_sucursal`, `ventas.fecha_venta` y `ventas.control_stock` quedan inmutables después de su creación.
- Las nuevas ventas quedan obligatoriamente en `control_stock='Integrado'`; las filas semilla son históricas y no participan en automatismos de stock.
- `ventas.total` se valida contra el subtotal de líneas y `descuento_total`.
- `ventas.costo_envio` se valida contra el peso total de sus líneas para ventas integradas.
- `clientes.total_gastado` y `fecha_ultimo_pedido` se tratan como datos derivados y se bloquea la modificación inconsistente.
- El email se normaliza/valida tanto en `INSERT` como en `UPDATE`.

### Pagos y devoluciones

- El monto del pago debe coincidir con `ventas.total + costo_envio`.
- Las transiciones de pago están restringidas a estados válidos y existen estados terminales para `Rechazado` y `Reembolsado`.
- No se pueden borrar pagos.
- Una aprobación de pago actualiza automáticamente la venta a `Pagado` cuando corresponde.
- Las devoluciones conservan inmutables venta, producto, cantidad, motivo y fecha; solo puede cambiar el estado de `Solicitada` a `Aprobada` o `Rechazada`.
- Aprobar una devolución ejecuta atómicamente reintegro de stock, registro en `ajustes_stock`, actualización del reembolso y cierre de la venta cuando todas las unidades fueron devueltas.
- El reembolso de una línea prorratea `ventas.descuento_total`, evitando sobre-reembolsos cuando existe descuento de pedido.

### Promociones

- Los descuentos porcentuales ya no pueden llegar al 100 %, manteniendo la compatibilidad con el requisito de precio final positivo.
- Las promociones de tipo `Monto` ahora participan realmente en la creación de la venta como descuento de pedido.
- `fn_CalcularTotalVenta` incorpora `descuento_total` al total neto.

### Seguridad

- Se eliminaron contraseñas iniciales hardcodeadas del repositorio.
- Las cuentas se crean con contraseña aleatoria, bloqueadas y expiradas; el secreto real se provisiona fuera del repositorio.
- Se conserva protección de intentos fallidos (`FAILED_LOGIN_ATTEMPTS=5`, `PASSWORD_LOCK_TIME=1`).
- `Analista_Datos` dejó de consultar directamente las tablas operativas sensibles de ventas, detalle, pagos, devoluciones y clientes; utiliza vistas analíticas limitadas.
- `Empleado_Inventario` no tiene `UPDATE` directo sobre `productos`; los ajustes pasan por `sp_AjustarStock`.
- Las vistas, funciones, triggers, eventos y procedimientos privilegiados tienen `DEFINER='root'@'localhost'` explícito para evitar depender accidentalmente del usuario que los creó.

### Instalación y mantenimiento

- Se añadió `00_Instalacion.sql` para centralizar el orden correcto de ejecución.
- Se añadió `08_Verificacion_Final.sql`, un smoke-test de solo lectura para validar objetos, totales, pagos, devoluciones y stock.
- `trg_audit_cliente_after_update.sql` quedó como referencia histórica comentada; la auditoría funcional de clientes está integrada en `05_Triggers.sql` y no se duplica.

## Resultado de la nueva auditoría

| Área | Resultado |
|---|---:|
| Conteo de funciones | 20/20 |
| Conteo de procedimientos | 20/20 |
| Conteo de triggers | 34/34 |
| Conteo de eventos | 20/20 |
| Conteo de vistas | 9/9 |
| Nombres de objetos únicos | OK |
| Delimitadores de objetos almacenados | OK |
| FK compuesta de devoluciones | OK |
| Integridad de líneas de venta | OK |
| Integridad de totales | OK |
| Integridad de pagos | OK |
| Integridad de devoluciones | OK |
| Integridad de stock | OK |
| Integridad de agregados de clientes | OK |
| Seguridad de credenciales | OK |
| Mínimo privilegio para analista/inventario | OK |
| Definers explícitos | OK |
| Instalador centralizado | OK |
| Alias SQL revisados | OK |
| Referencias a credenciales antiguas | 0 |
| Verificaciones estáticas totales | **50/50 PASS** |

## Hallazgos críticos de la auditoría inicial cerrados

1. Producto inexistente dentro de una devolución: **cerrado con FK compuesta**.
2. Venta con total manipulado: **cerrado con validación estructural por trigger**.
3. `total_gastado` manipulable: **cerrado con validación de dato derivado**.
4. Cambio de cliente de una venta: **bloqueado**.
5. Email inválido mediante `UPDATE`: **bloqueado**.
6. Promoción del 100 % incompatible con precio final: **corregido**.
7. Promociones `Monto` declaradas pero sin efecto: **implementadas**.
8. Contraseñas hardcodeadas: **eliminadas**.
9. Exposición excesiva del rol analítico: **reducida mediante vistas**.
10. Devolución solicitada que no podía avanzar de estado: **corregida**.
11. Reembolso con descuento de pedido: **prorrateado**.
12. Ventas nuevas marcadas como históricas: **bloqueadas**.
13. Dependencia implícita del creador como `DEFINER`: **endurecida con `root@localhost` explícito**.

## Validación operativa pendiente

Para cerrar la certificación al 100 % en el entorno destino se debe ejecutar la instalación en **MySQL 8.0+** y posteriormente `08_Verificacion_Final.sql`. Esto no es una modificación pendiente del repositorio, sino una validación de runtime que el entorno de auditoría actual no permite realizar.

El evento `ev_diario_backup_simulado` y el evento de optimización simulada siguen correctamente documentados como **simulaciones**. El respaldo real debe continuar gestionándose con una herramienta de backup como `mysqldump` o un sistema de respaldo equivalente.

## Conclusión

El proyecto queda en un estado **considerablemente más robusto y defendible** para evaluación académica o como base de una aplicación real. Las reglas críticas ya no dependen exclusivamente de la disciplina del procedimiento llamador y se redujo de forma importante la posibilidad de inconsistencias mediante DML directo.
