

<p align="center">
  <img src="zuko-logo.svg" width="128" height="128" alt="Zuko logo">
</p>

<h1 align="center">zuko</h1>

[![build](https://github.com/adonm/zuko/actions/workflows/build.yml/badge.svg)](https://github.com/adonm/zuko/actions/workflows/build.yml)
[![docs](https://github.com/adonm/zuko/actions/workflows/docs.yml/badge.svg)](https://zuko.adonm.dev/)
[![release](https://github.com/adonm/zuko/actions/workflows/release.yml/badge.svg)](https://github.com/adonm/zuko/releases/latest)
[![FlatPark](https://img.shields.io/badge/FlatPark-zuko-4A90D9?logo=flatpak)](https://flatpark.org/apps/dev.adonm.zuko/)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**Shells remotos privados para las máquinas que te pertenecen, sin abrir puertos entrantes ni operar una VPN.** Empareja una vez con un código corto y luego reconecta por nombre desde una terminal.

zuko ejecuta una PTY real sobre [Iroh](https://www.iroh.computer/), que proporciona accesibilidad mediante clave, atravesamiento de NAT, respaldo por retransmisión y cifrado de extremo a extremo. El núcleo soportado es deliberadamente pequeño: un host Linux/macOS, la CLI de Rust, autorización explícita de dispositivo y reconexiones breves.

## Inicio rápido

Instala la CLI en un host Linux o macOS:

```sh
curl --proto '=https' --tlsv1.2 -LsSf https://zuko.adonm.dev/install.sh | sh
# Reinicia tu shell aquí si el instalador lo solicita.
zuko install
```

Empareja desde otra máquina con la CLI instalada:

```sh
# host: imprime un código de una sola vez de dos palabras
zuko share

# cliente: reclama, guarda y conecta
zuko iridescent-hilton

# más tarde
zuko home
```

El instalador inicializa y activa mise cuando es necesario, luego instala Zuko como una herramienta global gestionada por mise. Reinicia tu shell primero si lo solicita. Consulta [Primeros pasos](docs/getting-started.md) para conocer mise, selección de versión, registros del servicio y la primera conexión. Los hosts Windows pueden usar la configuración documentada de [WSL2](docs/windows-wsl2.md), con limitaciones en el ciclo de vida.

El cliente gráfico para Linux está disponible desde el remoto Flatpak firmado de FlatPark:

```sh
flatpak --user remote-add --if-not-exists flatpark \
  https://dl.flatpark.org/flatpark.flatpakrepo
flatpak --user remote-add --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak --user install flatpark dev.adonm.zuko
```

Consulta la [página del paquete en FlatPark](https://flatpark.org/apps/dev.adonm.zuko/) y las [notas de entrega para Linux](docs/flatpark.md) para conocer los permisos del entorno restringido (sandbox) y los requisitos del llavero. FlatPark es un repositorio comunitario independiente y no está afiliado a Flathub.

## Ámbito del producto

| Nivel | Plataforma | Compromiso |
|------|---------|------------|
| **Núcleo** | Host Linux/macOS y CLI de Rust | Flujo de trabajo principal soportado |
| **Beta** | Clientes Flutter para Android, iOS/iPadOS, macOS y Linux | Cliente gráfico compartido con rutas de entrega mediante tiendas, vista previa o paquetes comunitarios |
| **Laboratorios** | Clientes Flutter web/Windows y `zuko app` para Linux | Desplegado o compilable, con brechas específicas del canal documentadas a continuación |

Consulta [Clientes](docs/clients.md) para conocer las capacidades exactas y el canal de entrega de cada destino, y la [guía de compilación de clientes](docs/building-clients.md) para compilaciones recientes en Android, Apple, web, Linux y Windows.

La entrega completamente firmada a través de tiendas públicas para las plataformas gráficas aún está en desarrollo. Para pruebas, los artefactos con suma de verificación en la [última versión de GitHub](https://github.com/adonm/zuko/releases/latest) son la fuente preferida; la página de Clientes documenta las brechas específicas de cada plataforma y el canal interno separado de TestFlight.

zuko no es un gestor de sesiones perdurables, un escritorio remoto completo ni un sistema centralizado de acceso a flotas. Usa `tmux`, `zellij` o `screen` para trabajos que deban sobrevivir a desconexiones y reinicios del host.

## Uso

```sh
zuko <name>              # conectar
zuko                     # selector de TTY / lista sin TTY
zuko share               # autorizar un nuevo cliente
zuko claim <code> --as x # formulario de reclamación explícito
zuko doctor              # verificar servicio, ticket, estado y red
# dentro de un shell de host conectado:
zuko tunnel 8000         # bucle local del cliente → host 127.0.0.1:8000
zuko files               # servidor dufs en primer plano + túnel autenticado
```

Notas sobre la sesión:

- PTY real del host; los bytes se reenvían textualmente.
- Vigencia de PTY desanexada: 5 minutos. Sin búfer de reproducción.
- Usa `tmux`, `zellij` o `screen` para trabajos perdurables.
- Salida forzada de CLI: Ctrl-C tres veces en ~1s sin salida remota.

## Túneles TCP temporales

Ejecuta `zuko tunnel <port>` dentro de un shell abierto a través de Zuko. El cliente nativo vincula un puerto efímero de bucle local, lo muestra y abre su URL HTTP para el caso común de servidor web local. El tráfico es TCP en bruto: Zuko no analiza HTTP ni termina TLS, por lo que el puerto mostrado también funciona con HTTPS, WebSockets, SSH y otros clientes TCP.

```sh
# En el host, dentro del shell conectado:
python3 -m http.server 8000 --bind 127.0.0.1 &
zuko tunnel 8000
```

El comando permanece en primer plano e informa los totales de conexiones/bytes. Ctrl-C cierra el túnel de Iroh y el puerto del cliente. Consulta [`docs/tunnel.md`](docs/tunnel.md).

Para un explorador de archivos temporal con escritura, ejecuta `zuko files` desde el directorio que deseas compartir. Utiliza `dufs` desde `PATH`, o instala una versión fija de dufs a través de mise si falta, lo vincula al bucle local del host y mantiene tanto los registros de acceso de dufs como las estadísticas del túnel en primer plano. El modo requerido `dufs -A` otorga acceso anónimo a carga, eliminación, archivado, búsqueda y accesos directos simbólicos a través de la URL temporal de bucle local del cliente. Presiona Ctrl-C tan pronto como finalice el uso compartido.

## Laboratorios: `zuko app` (Linux)

Ejecuta una aplicación con interfaz gráfica dentro de un shell de zuko existente. La salida son gráficos Kitty a través de la misma conexión PTY/Iroh. Esta es una función opcional de Laboratorios, no un objetivo de escritorio remoto.

```sh
zuko app --list
zuko app firefox
zuko app --doctor
```

Consulta [`docs/app.md`](docs/app.md).

## Compilación/pruebas

Los colaboradores de Linux utilizan un Distrobox de Ubuntu 24.04 con versión fija como entorno de desarrollo principal. Ingresa a él y activa Mise antes de ejecutar comandos del repositorio; [`docs/building-clients.md`](docs/building-clients.md) enumera los requisitos previos del contenedor, del sistema, de Android y de la plataforma.

```sh
mise trust
mise bootstrap
eval "$(mise activate bash)"
hk install --mise # formato local y verificaciones completas pre-push
just check
just test-e2e      # red Iroh en vivo + PTY
cargo build --release
```

Los requisitos previos de la plataforma, los comandos de Windows PowerShell, el comportamiento de firma y las rutas de los artefactos están en [Compilación de clientes](docs/building-clients.md).

## Mapa del repositorio

| Ruta | Contenidos |
|------|----------|
| `src/` | Crate de Rust: host, cliente CLI, traspaso, servicio y transmisión de aplicaciones |
| `flutter/` | Cliente compartido para Android, iOS, macOS, web, Linux y Windows |
| `Justfile` | Recetas de compilación, pruebas, empaquetado y lanzamiento orientadas al usuario |
| `mise.toml` | Herramientas fijas, entorno y dependencias del sistema para inicialización |
| `docs/` | Documentación mdBook |
| `tests/e2e.rs` | prueba de integración de red en vivo (ignorada) |
| `.github/workflows/` | CI de Rust, Flutter, lanzamiento, TestFlight y documentación |

## Seguridad

El acceso al shell requiere tanto la información de conexión del host como un token de cliente autorizado. `zuko share` transfiere lo primero y registra lo segundo a través de un traspaso cifrado de extremo a extremo. Mantén ambos en privado y revoca clientes perdidos con `zuko rm <name>`.

Informa vulnerabilidades a través de GitHub Security Advisory. Detalles:
[`docs/security.md`](docs/security.md).

## Licencia

Apache-2.0. Consulta [`LICENSE`](LICENSE).
