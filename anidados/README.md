# CloudFormation con plantillas anidadas + sincronización con Git

Despliega los **mismos 2 servidores** del proyecto (backend Node 20 + MySQL y frontend nginx, sin Docker) con **CloudFormation**, dividido en plantillas anidadas. **Cada push a `main` actualiza AWS solo.**

```
                 main.yaml  (stack principal: asistencia-dev)
                     │
   ┌─────────────┬───┴─────────┬──────────────────┬──────────────────────┐
   ▼             ▼             ▼                  ▼                      ▼
 red.yaml   seguridad.yaml  identidad.yaml   servidor.yaml          servidor.yaml
 VPC,       Security        llave SSH,       Rol=backend            Rol=frontend
 subred,    Groups          secreto admin,   Node+MySQL :8000  ◄──  nginx :80
 IGW        (22/80/8000)    rol IAM                            IP privada
```

## Estructura

| Archivo | Qué hace |
|---|---|
| `main.yaml` | Stack principal: recibe parámetros y conecta las capas (salidas de una → entradas de otra) |
| `red.yaml` | Capa 1: VPC propia, subred pública, Internet Gateway y rutas |
| `seguridad.yaml` | Capa 2: Security Groups (SSH solo tu IP, 3306 cerrado, salida solo 80/443) |
| `identidad.yaml` | Capa 3: llave SSH, contraseña del admin en Secrets Manager, rol IAM mínimo |
| `servidor.yaml` | Capa 4: **una sola plantilla EC2 reutilizada** para backend y frontend (IMDSv2, disco cifrado) |
| `parametros/dev.env` | Valores del ambiente dev (tu IP, rama, etc.) |
| `conexion/github-oidc.yaml` | Conexión GitHub ↔ AWS. **Se crea una sola vez, a mano** |
| `escanear.ps1` | Corre los 3 escáneres en tu PC |
| `../.github/workflows/cloudformation.yml` | El pipeline: valida, escanea y despliega |
| `../docs/seguridad/inseguro.yaml` | Plantilla con errores a propósito, para mostrar el "antes" del escaneo |

### Qué se refactorizó respecto a la primera versión de `anidados/`

| Antes | Ahora |
|---|---|
| `red.yaml` no era una plantilla válida | Crea una VPC propia: el stack funciona igual en cualquier cuenta |
| SSH y HTTP abiertos a `0.0.0.0/0` en un único SG | 2 SG: SSH solo desde `MiIp`, API 8000 solo desde el frontend |
| Servidores con Apache de prueba | La aplicación real (mismos scripts que `v2/aws` de OpenTofu) |
| `TemplatesS3BucketUrl` había que subirlo a mano | El pipeline sube las hijas a S3 con `aws cloudformation package` |
| — | Nueva capa `identidad.yaml`: secretos sin texto plano y rol con mínimo privilegio |
| Se mantiene | Ambientes `dev/qa/prod` con `Mappings` y la plantilla `servidor.yaml` reutilizable |

---

## ¿Por qué GitHub Actions y no "Sync from Git" de la consola?

- En las plantillas anidadas, cada `TemplateURL` **debe ser una URL de S3**: CloudFormation no lee plantillas hijas desde GitHub.
- "Sync from Git" de la consola despliega **un solo archivo** del repositorio y no sube las hijas a S3.
- El workflow hace lo mismo que Git sync (el repo es la fuente de la verdad: push → AWS se actualiza), y además sube las hijas a S3 y corre los escáneres **antes** de desplegar.
- El workflow **no modifica el código** de nadie. Es un archivo que GitHub ejecuta cuando alguien hace push.

---

## Paso 1: Conectar GitHub con AWS (una sola vez)

Lo hace **una persona** con acceso de administrador a la cuenta AWS.

1. **IAM → Identity providers**: fíjate si ya existe `token.actions.githubusercontent.com`.
   - Si **no existe**: deja `CrearProveedorOidc = true`.
   - Si **ya existe**: pon `CrearProveedorOidc = false` (solo puede haber uno por cuenta).
2. **CloudFormation → Create stack → With new resources → Upload a template file** → `anidados/conexion/github-oidc.yaml`.
3. **Stack name:** `conexion-github-asistencia`. No uses un nombre que empiece con `asistencia-`, porque ese prefijo queda reservado para los stacks del pipeline.
4. Deja los valores por defecto (`escobarnina` / `Mi-asistencia` / `main`) → Next → Next → marca **"I acknowledge that AWS CloudFormation might create IAM resources with custom names"** → **Submit**.
5. Cuando diga `CREATE_COMPLETE`, revisa la pestaña **Outputs**. Verás 2 roles y 1 bucket:

| Recurso | Para qué |
|---|---|
| `asistencia-github-actions` | Rol que asume GitHub, **solo** desde `escobarnina/Mi-asistencia` rama `main`, sin llaves guardadas |
| `asistencia-cfn-ejecucion` | Rol que usa CloudFormation para crear los recursos; GitHub solo puede "pasárselo" |
| `asistencia-cfn-plantillas-<cuenta>` | Bucket privado y cifrado donde se suben las plantillas hijas |

6. En `.github/workflows/cloudformation.yml`, comprueba que `AWS_ACCOUNT_ID` sea el número de **tu** cuenta (arriba a la derecha en la consola). Viene con `345594582894`.

En GitHub no hay que configurar secretos: el número de cuenta y los nombres de los roles no son datos secretos, y la seguridad la da la condición del rol (repo + rama).

## Paso 2: Completar los parámetros

En `anidados/parametros/dev.env` reemplaza `MiIp=X.X.X.X/32` por tu IP (https://checkip.amazonaws.com) + `/32`. Si se queda como `X.X.X.X`, el pipeline se detiene con un aviso.

## Paso 3: Subir los cambios (y ver cómo se despliega)

```powershell
git switch feat/cloudformation-gitsync
git add anidados .github docs/seguridad
git commit -m "CloudFormation anidado + pipeline Git"
git push -u origin feat/cloudformation-gitsync
```

1. Abre el **Pull Request** hacia `main`. Corre el job **"Validar y escanear"** (no toca AWS). Los reportes quedan en *Actions → la ejecución → Artifacts → reportes-seguridad*.
2. Haz **merge** a `main`. Corre **"Desplegar en AWS"**:
   - `package` sube las hijas a S3 y cambia cada `TemplateURL` por su URL de S3;
   - `deploy` crea o actualiza el stack `asistencia-dev`.
3. En **CloudFormation** verás el stack `asistencia-dev` y 5 stacks anidados (marcados como *NESTED*).
4. El **Summary** de la ejecución muestra las URLs. Espera 5–8 min después de terminar (las VMs instalan todo) y abre `HealthViaFrontend` → `{"status":"ok"}`.

## Paso 4: Demo "otro integrante actualiza"

Un compañero cambia algo, por ejemplo en `parametros/dev.env`:

```
BackendPublico=false
```

Luego hace commit, push, PR y merge a `main`. El pipeline corre solo y en **CloudFormation → asistencia-dev → Events** se ve `UPDATE_IN_PROGRESS` → `UPDATE_COMPLETE`. Solo se actualiza el stack anidado de **seguridad**: desaparece la regla del puerto 8000 público y los servidores no se tocan. Eso demuestra la ventaja de las capas.

Otros cambios seguros para la demo: una etiqueta, la descripción de una regla o `RepoRama`.

## Ver credenciales

| Qué | Dónde |
|---|---|
| Contraseña del admin | Output `SecretoAdmin` → Secrets Manager → *Retrieve secret value* |
| Llave SSH (.pem) | Output `LlavePrivadaEnParameterStore` → Systems Manager → Parameter Store → *Show decrypted value* |

## Borrar (para no gastar)

**CloudFormation → `asistencia-dev` → Delete.** Borra los 5 stacks anidados y todos sus recursos. El stack `conexion-github-asistencia` puede quedar (no cuesta nada); bórralo solo al final de la materia.

Si un despliegue falla **la primera vez**, el stack queda en `ROLLBACK_COMPLETE` y no se puede actualizar. Bórralo a mano en la consola y vuelve a correr el workflow (*Actions → CloudFormation (anidados) → Run workflow*).

---

## Seguridad: los 3 escáneres

| # | Escáner | Etapa de la cadena | Qué revisa |
|---|---|---|---|
| 0 | cfn-lint | Validación (bloquea el pipeline) | Sintaxis y propiedades válidas de AWS |
| 1 | **cfn-nag** | 5. Análisis estático | Reglas de seguridad propias de CloudFormation |
| 2 | **Trivy** | 5. Análisis estático | Malas configuraciones IaC (el mismo escáner del proyecto OpenTofu) |
| 3 | **KICS** | 7. Cumplimiento | Controles CIS/NIST, reporte HTML |

En tu PC (con Docker Desktop):

```powershell
.\anidados\escanear.ps1 -Ruta docs\seguridad   # ANTES: plantilla insegura
.\anidados\escanear.ps1                         # DESPUÉS: plantillas anidadas
```

En el pipeline, los 3 escáneres **informan** sin bloquear: quedan hallazgos que aceptamos a conciencia (tabla siguiente). cfn-lint sí bloquea.

### Hallazgos aceptados (riesgo aceptado)

| Hallazgo | Justificación |
|---|---|
| Puerto 80 abierto a internet | Es la página pública del sistema |
| Salida 80/443 a `0.0.0.0/0` | Las VMs descargan paquetes (apt, NodeSource, npm, GitHub) |
| Puerto 8000 público (`BackendPublico=true`) | El docente pide el backend publicado; con `false` se cierra |
| Subred con IP pública automática | Acceso por IP, sin dominio ni balanceador |
| Secreto sin llave KMS propia | La llave de AWS es gratuita; una CMK cuesta 1 USD/mes |
| Bucket de plantillas sin access logging | Solo guarda plantillas; el logging necesita otro bucket |
| Sin VPC Flow Logs ni monitoreo detallado | Costo extra; el monitoreo básico gratuito basta para el proyecto |
| Solo HTTP | Falta dominio + certificado |
