# [uhotspot](https://github.com/maravento) — UniFi Hotspot Manager for Linux

[![status-maintained](https://img.shields.io/badge/status-maintained-purple.svg)](https://github.com/maravento/uhotspot)
[![last commit](https://img.shields.io/github/last-commit/maravento/uhotspot)](https://github.com/maravento/uhotspot)
[![Stargazers](https://img.shields.io/github/stars/maravento/uhotspot?label=Stargazers)](https://github.com/maravento/uhotspot/stargazers)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/maravento/uhotspot)
[![Twitter Follow](https://img.shields.io/twitter/follow/maraventostudio.svg)](https://twitter.com/maraventostudio)

<!-- markdownlint-disable MD033 -->

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>uhotspot</b> is a systemd daemon that turns a self-hosted UniFi Network controller into a fully managed captive-portal hotspot under Linux. It queries the UniFi API every POLL_INTERVAL seconds (default 20, configured in <code>uhotspot.conf</code>) and synchronizes ACL files (<code>umacauth.txt</code>, <code>ugrace.txt</code>, <code>umacbak.txt</code>) with the real state reported by the controller. Firewall enforcement is delegated to user-maintained <code>ipset</code>/<code>iptables</code> rules that are reloaded whenever the ACLs change. It is the cheap-but-serious alternative for sysadmins who could only afford a UniFi AP and still need to enforce vouchers, proxy, and per-MAC restrictions.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>uhotspot</b> es un daemon systemd que convierte un controlador UniFi Network self-hosted en un hotspot con portal cautivo completamente administrado bajo Linux. Consulta la API de UniFi cada POLL_INTERVAL segundos (default 20, configurado en <code>uhotspot.conf</code>) y sincroniza archivos ACL (<code>umacauth.txt</code>, <code>ugrace.txt</code>, <code>umacbak.txt</code>) con el estado real reportado por el controlador. El bloqueo se delega a reglas <code>ipset</code>/<code>iptables</code> mantenidas por el usuario, que se recargan cuando las ACLs cambian. Es la alternativa barata pero seria para sysadmins que apenas alcanzaron a comprar un AP UniFi y aun así necesitan aplicar vouchers, proxy y restricciones por MAC.
    </td>
  </tr>
</table>

## Requirements

---

**⚠️ WARNING:** Only tested on Ubuntu 24.04 LTS. Other versions or distros not tested, use at your own risk.

### Hardware

| Resource | Minimum |
|----------|---------|
| CPU | 2 cores @ 1 GHz |
| RAM | 256 MB |
| Disk | 100 MB |

### Software

| Component | Tested Version |
|-----------|-----------------|
| UniFi OS Server | 5.1.15 |
| UniFi Network (self-hosted) | 10.4.57 |
| `iptables` | 1.8.10 |
| `ipset` | 7.19 |
| `pydhcpd` | latest |

### Mandatory

| Component | Used by | Purpose | Propósito |
|-----------|---------|---------|-----------|
| **UniFi Network (self-hosted)** | `uhotspotd`, `uaudit.sh` | Captive portal SSID, vouchers, and the API Site must be **Third-Party Gateway**. Local admin account | SSID de portal cautivo, vouchers, y el Site de la API debe ser **Third-Party Gateway**. Cuenta de admin local |
| **pydhcp** | `uhotspotd` (verified at startup) | DHCP backend. Exactly one must be active | Backend DHCP. Exactamente uno debe estar activo |
| **iptables** + **ipset** | system administrator | Firewall enforcement of ACL files (must be configured manually) | Aplicación de firewall de los archivos ACL (debe configurarse manualmente) |
| **bash**, **curl**, **jq**, **cron** | `uhotspotd`, `uaudit.sh`, `uleases.sh` | Script runtime, UniFi API, JSON parsing, scheduling | Runtime de scripts, API de UniFi, parseo de JSON, programación |

### Optional

| Component | When it's needed | Cuándo se necesita |
|-----------|-------------------|---------------------|
| **squid**, **apache2**, DHCP option 252 (WPAD) | Only if your network uses [proxymon](https://github.com/maravento/proxymon) (Squid-based filtering) — `apache2` hosts the WPAD/PAC file, and WPAD lets clients auto-discover the proxy. See that project for installation and configuration details. | Solo si su red usa [proxymon](https://github.com/maravento/proxymon) (filtrado basado en Squid) — `apache2` sirve el archivo WPAD/PAC, y WPAD permite que los clientes descubran el proxy automáticamente. Consulte ese proyecto para detalles de instalación y configuración. |

```bash
# Required packages
sudo apt update
sudo apt install -y bash curl jq iptables ipset cron python3

# DHCP backend — install pydhcp:
#   • pydhcp — https://github.com/maravento/pydhcp

# Optional
sudo apt install -y squid apache2
```

> Without UniFi reachable or without `pydhcpd` running (beyond their respective startup grace windows), `uhotspot` refuses to start. Without a working `uiptables.sh`, the daemon still starts and keeps classifying clients (grace/authorized/blocked) normally, but firewall enforcement is skipped with a log warning until it's configured. These are hard dependencies for full functionality.
>
> Sin UniFi alcanzable o sin `pydhcpd` corriendo (más allá de sus respectivas ventanas de gracia de arranque), `uhotspot` se niega a arrancar. Sin un `uiptables.sh` funcional, el daemon igual arranca y sigue clasificando clientes (gracia/autorizado/bloqueado) normalmente, pero se salta la aplicación del firewall con una advertencia en el log hasta que se configure. Son dependencias duras para la funcionalidad completa.

## SCOPE

---

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>What uhotspot does:</b>
      <ul>
        <li>Polls the UniFi Controller API (local account)</li>
        <li>Reads <code>UNIFI_TYPE</code> from <code>uhotspot.conf</code>. <code>usetup.sh</code> auto-detects <code>unifi-os</code> or <code>classic</code> on ports 8443/11443 at install time; if neither responds, it warns and lets you enter the controller URL and type manually. <code>uhotspotd.sh</code> supports both: <code>unifi-os</code> (UDM/UDM-Pro/UDR/Cloud Key Gen2+, <code>/api/auth/login</code>, <code>TOKEN</code> cookie, CSRF from the JWT payload) and <code>classic</code> (self-hosted UniFi Network Application, <code>/api/login</code>, <code>unifises</code> cookie, CSRF from the response header)</li>
        <li>Classifies guest-SSID clients into three states: <i>grace</i> (timer running, no voucher yet), <i>authorized</i> (active voucher), and <i>blocked</i> (grace expired without a voucher)</li>
        <li>Checks that <code>pydhcpd</code> is active on startup, retrying quietly for up to <code>STARTUP_GRACE_SECONDS</code> (same grace window as the UniFi login below) before aborting</li>
        <li>Queues <code>dhcpd.leases</code> removals for MACs it manages (consumed by <code>uleases.sh</code> during its safe DHCP stop→modify→start cycle)</li>
        <li>Calls a user-defined <code>SERVER_RELOAD_SCRIPT</code> when ACLs actually changed (md5 diff), or on the safety-net cadence below</li>
        <li>Runs as a <b>systemd service</b> (<code>uhotspotd.service</code>) installed by <code>usetup.sh</code>; the daemon forces its own safety-net reload every <code>RELOAD_SAFETY_INTERVAL_SECONDS</code> (default one hour) so grace→block promotion still happens on idle networks — no external cron entry needed</li>
        <li>Managed MAC lists (<code>mac-*.txt</code>): the daemon never authorizes or otherwise processes these -- corporate/infrastructure devices bypass the captive portal entirely at the DHCP level, handled exclusively by <code>uleases.sh</code> on reload. A live, on-disk check guards the two guest-flow entry points so a stale or externally-granted UniFi guest session for one of these devices can never be promoted into the hotspot list</li>
        <li>Logrotate config <code>/etc/logrotate.d/uhotspot</code> created by <code>usetup.sh</code> via <code>install_logrotate()</code> (daily, 7 rotations, compressed). All output unified in <code>/var/log/uhotspot.log</code></li>
        <li>Reads configuration from <code>/etc/uhotspot/uhotspot.conf</code> (generated by <code>usetup.sh</code>, root-only, mode 0600)</li>
        <li>Validates installation integrity before each run <code>verify_installation()</code></li>
        <li>IPv4 only</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Lo que uhotspot hace:</b>
      <ul>
        <li>Consulta la API del controlador UniFi (cuenta local)</li>
        <li>Lee <code>UNIFI_TYPE</code> de <code>uhotspot.conf</code>. <code>usetup.sh</code> autodetecta <code>unifi-os</code> o <code>classic</code> en los puertos 8443/11443 durante la instalación; si ninguno responde, avisa y permite ingresar la URL y el tipo de controlador manualmente. <code>uhotspotd.sh</code> soporta ambos: <code>unifi-os</code> (UDM/UDM-Pro/UDR/Cloud Key Gen2+, <code>/api/auth/login</code>, cookie <code>TOKEN</code>, CSRF desde el payload del JWT) y <code>classic</code> (UniFi Network Application autohospedado, <code>/api/login</code>, cookie <code>unifises</code>, CSRF desde el header de respuesta)</li>
        <li>Clasifica los clientes del SSID de invitados en tres estados: <i>gracia</i> (contador activo, sin voucher), <i>autorizados</i> (con voucher activo) y <i>bloqueados</i> (gracia expirada sin voucher)</li>
        <li>Verifica que <code>pydhcpd</code> esté activo en el arranque, reintentando en silencio hasta <code>STARTUP_GRACE_SECONDS</code> (misma ventana de gracia que el login de UniFi abajo) antes de abortar</li>
        <li>Encola remociones de <code>dhcpd.leases</code> para los MACs que gestiona (consumidas por <code>uleases.sh</code> durante su ciclo seguro de detener→modificar→arrancar DHCP)</li>
        <li>Invoca un <code>SERVER_RELOAD_SCRIPT</code> definido por el usuario cuando las ACLs realmente cambiaron (md5 diff), o en la cadencia de seguridad de abajo</li>
        <li>Corre como <b>servicio systemd</b> (<code>uhotspotd.service</code>) instalado por <code>usetup.sh</code>; el daemon fuerza su propio reload de seguridad cada <code>RELOAD_SAFETY_INTERVAL_SECONDS</code> (default una hora) para que la promoción gracia→bloqueo siga ocurriendo en redes inactivas — sin necesidad de cron externo</li>
        <li>Listas de MACs gestionadas (<code>mac-*.txt</code>): el daemon nunca las autoriza ni las procesa de otra forma -- los dispositivos corporativos/de infraestructura bypasean el portal cautivo enteramente a nivel DHCP, gestionado en exclusiva por <code>uleases.sh</code> en cada reload. Una comprobación en vivo, leyendo el disco, protege los dos puntos de entrada al flujo de invitados para que una sesión de invitado residual o concedida fuera del daemon nunca promueva a uno de estos dispositivos a la lista de hotspot</li>
        <li>Configuración de logrotate <code>/etc/logrotate.d/uhotspot</code> creada por <code>usetup.sh</code> vía <code>install_logrotate()</code> (diario, 7 rotaciones, comprimido). Toda la salida unificada en <code>/var/log/uhotspot.log</code></li>
        <li>Lee su configuración de <code>/etc/uhotspot/uhotspot.conf</code> (generado por <code>usetup.sh</code>, solo root, modo 0600)</li>
        <li>Valida la integridad de la instalación antes de cada ejecución mediante <code>verify_installation()</code></li>
        <li>Solo IPv4</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Out of scope (not implemented):</b>
      <ul>
        <li>Does NOT provide DHCP — relies on an external DHCP server</li>
        <li>Does NOT support DHCP backends other than <code>pydhcpd</code> (no <code>dnsmasq</code>, <code>isc-dhcp-server</code>, no others)</li>
        <li>Does NOT touch <code>iptables</code> or <code>ipset</code> directly — that is delegated to <code>SERVER_RELOAD_SCRIPT</code></li>
        <li>Does NOT support IPv6</li>
        <li>Does NOT support multiple guest SSIDs simultaneously</li>
        <li>Does NOT replace a UDM, Cloud Key, or any UniFi gateway hardware</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Fuera de alcance (no implementado):</b>
      <ul>
        <li>NO provee DHCP — depende de un servidor DHCP externo</li>
        <li>NO soporta otros backends DHCP que no sean <code>pydhcpd</code> (no <code>dnsmasq</code>, <code>isc-dhcp-server</code>, ni otros)</li>
        <li>NO toca <code>iptables</code> ni <code>ipset</code> directamente — eso lo delega al <code>SERVER_RELOAD_SCRIPT</code></li>
        <li>NO soporta IPv6</li>
        <li>NO soporta múltiples SSID de invitados simultáneamente</li>
        <li>NO reemplaza UDM, Cloud Key ni hardware gateway de UniFi</li>
      </ul>
    </td>
  </tr>
</table>

## REPOSITORY STRUCTURE

---

This is the layout of the cloned repository (`git clone ... && cd uhotspot`), not the installed path — `usetup.sh` and `tools/uiptables_example.sh` never leave the clone; everything else under `core/` and `tools/` (except the example) is deployed by `usetup.sh` to the matching subdirectory under `/etc/uhotspot/`.

```
uhotspot/            # as cloned -- see note above
├── usetup.sh          # installer / updater / uninstaller (interactive);
│                      # run from here, never deployed to /etc/uhotspot/
├── core/              # the reload mechanism itself -- uhotspot cannot
│                      # function without any of these
│   ├── uhotspotd.sh         # main daemon -- UniFi API poller + ACL manager (systemd)
│   ├── uhotspotd.service    # systemd service unit
│   ├── ureload.sh           # wrapper invoked by uhotspotd after ACL changes;
│   │                        # calls uleases.sh and triggers reload of services
│   └── uleases.sh           # reimplementation of pydhcp's pyleases.sh,
│                            # with built-in UniFi Hotspot integration
├── tools/             # independent, optional utilities -- uhotspot runs
│                      # fine without any of these
│   ├── ucheck.sh            # interactive MAC diagnostic / consistency checker (menu-driven)
│   ├── uaudit.sh            # UniFi clients/vouchers audit tool
│   ├── ualert.sh            # optional standalone alert watcher -- tails the log,
│   │                        # pushes notifications via ntfy.sh
│   ├── uwatch.sh            # optional standalone services watchdog (uhotspotd,
│   │                        # ualert, UniFi backend) -- installs its own cron entry
│   ├── uhotspotmon.sh       # Webmin module installer/uninstaller — real-time log viewer
│   │                        # for uhotspotd (AJAX polling, dark mode, level badges, grep)
│   └── uiptables_example.sh # reference firewall ruleset -- ipsets/iptables/redirects
│                            # (NOT deployed by usetup.sh; the administrator copies it
│                            # manually to tools/uiptables.sh and adapts it)
└── acl/               # uhotspot's OWN data files -- empty templates in the repo,
                       # deployed once by usetup.sh and never overwritten again
    ├── umacauth.txt         # authenticated clients with vouchers (fixed hotspot IP)
    ├── umacbak.txt          # cumulative voucher-history whitelist (manual editing)
    ├── uqueue.txt           # internal working file (uhotspotd.sh / uleases.sh only)
    └── ugrace.txt           # grace-period clients (no voucher yet)
```

### ACL / data files — path ownership

`uhotspot` integrates three independent projects (UniFi, `pydhcp`, and the administrator's own `iptables`/`ipset` setup), each with its own ACL path. `uhotspot` reads/writes each one at its own location and never relocates files it does not own.

```
/etc/uhotspot/acl/                # uhotspot's OWN data files (generated by this project;
                                  # shipped as empty templates in the repo's acl/ folder,
                                  # deployed once by usetup.sh, never overwritten again)
├── umacauth.txt                       # voucher-authorized clients (fixed hotspot IP)
├── umacbak.txt                        # cumulative voucher-history whitelist
├── uqueue.txt                         # internal working file (uhotspotd.sh / uleases.sh only)
└── ugrace.txt                         # grace-period clients (no voucher yet)

/etc/acl/acl_mac/                 # pydhcp's namespace -- NOT generated by uhotspot
├── mac-proxy.txt                      # user-maintained; uhotspot only reads it
└── mac-unlimited.txt                  # user-maintained; uhotspot only reads it

/etc/acl/acl_dhcp/                # pydhcp/iptables namespace -- NOT generated by uhotspot
└── blockdhcp.txt                      # permanently blocked MACs; pydhcp/pyleases.sh concept,
                                       # reused (not owned) by uleases.sh
```

`ACL_MAC_PATH` (`/etc/acl/acl_mac`), `ACL_DHCP_PATH` (`/etc/acl/acl_dhcp`) and their file variables are configurable in `uhotspot.conf` precisely because those directories belong to other projects — `uhotspot` must respect whatever path the administrator already has configured for `pydhcp`/`iptables`, not impose its own. `uhotspot.conf` itself lives at `/etc/uhotspot/` (not inside `acl/`, since it is configuration, not a data list). Only `/etc/uhotspot/acl/` is this project's own and moves together with it (see [Remove](#remove) / [Update](#update)).

## ARCHITECTURE

---

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>uhotspot</b> is glue between UniFi (state of truth), the DHCP backend (lease assignment), and the firewall (enforcement). It only writes ACL files; everything else is invoked through <code>SERVER_RELOAD_SCRIPT</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>uhotspot</b> es código pegamento entre UniFi (estado verdadero), el backend DHCP (asignación de leases) y el firewall (aplicación). Solo escribe archivos ACL; todo lo demás se invoca a través del <code>SERVER_RELOAD_SCRIPT</code>.
    </td>
  </tr>
</table>

```
uhotspotd.sh  (systemd daemon — every POLL_INTERVAL seconds, default 20)
    │
    ▼
SERVER_RELOAD_SCRIPT
    │
    ├── DHCP lease reload
    │   └── uleases.sh
    │
    └── Firewall/ipset reload
        └── administrator-defined
```

## UNIFI PRE-CONFIGURATION

---

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Before running <code>uhotspotd</code>, in the UniFi Network controller:
      <ol>
        <li><b>Guest SSID</b>: enable Hotspot / Captive Portal.</li>
        <li><b>Landing Page</b>: select <i>Success Message</i> instead of a custom redirect URL — this is what allows iptables to capture the client's authentication chain. Do <b>not</b> enable <i>HTTPS Redirection Support</i>, <i>Encrypted URL</i>, <i>Secure Portal</i>, or <i>Domain</i> — the portal must be served over plain HTTP (e.g. <code>http://&lt;controller-ip&gt;:8880/guest/s/default/</code>).</li>
        <li>Do <b>not</b> use <i>Pre-Authorization Allowances</i> or <i>Post-Authorization Restrictions</i> — they interfere with iptables' redirect of the client's authentication flow.</li>
        <li><b>Optional</b>: uncheck <i>Client Device Isolation</i> if you intend to share Samba folders (devices will then be able to see each other).</li>
        <li><b>Optional, best practice</b>: enable <i>UAPSD</i> — improves battery life and latency for Wi-Fi clients (WMM power-save). Does not affect <code>uhotspot</code>'s MAC-based tracking.</li>
        <li><b>Optional, best practice</b>: enable <i>Proxy ARP</i> — improves wireless efficiency (the AP answers ARP/NDP requests on behalf of known clients instead of broadcasting them over the air). Does not affect <code>uhotspot</code>'s MAC-based tracking.</li>
        <li>Do <b>not</b> enable 2FA on the account — otherwise <code>uhotspotd</code> cannot authenticate against the UniFi API.</li>
        <li><b>Site name</b>: if your admin renamed the UniFi site from <code>default</code>, you must update <code>UNIFI_SITE</code> in <code>/etc/uhotspot/uhotspot.conf</code> accordingly.</li>
        <li><b>If the controller host has two NICs</b> (WAN + LAN), set <code>system_ip</code> in <code>/var/lib/unifi/system.properties</code> to the LAN IP and restart UniFi.</li>
        <li><b>Wi-Fi 7 APs</b>: disable <i>MLO (Multi-Link Operation)</i> on the guest SSID. IEEE 802.11be defines a Multi-Link Device (MLD) address separate from each physical link's own MAC address — since <code>uhotspot</code> tracks and authorizes clients strictly by MAC (DHCP static reservations, UniFi API, iptables/ipset), an MLO client could be seen inconsistently across those layers. This is a Wi-Fi 7 standard characteristic, not a UniFi-specific bug.</li>
      </ol>
    </td>
    <td style="width: 50%; vertical-align: top;">
      Antes de ejecutar <code>uhotspotd</code>, en el controlador UniFi Network:
      <ol>
        <li><b>SSID de invitados</b>: habilitar Hotspot / Portal Cautivo.</li>
        <li><b>Landing Page</b>: seleccionar <i>Success Message</i> en lugar de una URL de redirección personalizada — esto es lo que le permite a iptables capturar la cadena de autenticación del cliente. <b>No</b> habilitar <i>HTTPS Redirection Support</i>, <i>Encrypted URL</i>, <i>Secure Portal</i> ni <i>Domain</i> — el portal debe servirse por HTTP plano (ej. <code>http://&lt;ip-controlador&gt;:8880/guest/s/default/</code>).</li>
        <li><b>No</b> usar <i>Pre-Authorization Allowances</i> ni <i>Post-Authorization Restrictions</i> — interfieren con la redirección de iptables del flujo de autenticación del cliente.</li>
        <li><b>Opcional</b>: desmarcar <i>Client Device Isolation</i> si va a compartir carpetas Samba (los equipos podrán verse entre sí).</li>
        <li><b>Opcional, buena práctica</b>: activar <i>UAPSD</i> — mejora la duración de batería y la latencia de los clientes Wi-Fi (ahorro de energía WMM). No afecta el rastreo por MAC de <code>uhotspot</code>.</li>
        <li><b>Opcional, buena práctica</b>: activar <i>Proxy ARP</i> — mejora la eficiencia inalámbrica (el AP responde solicitudes ARP/NDP en nombre de clientes conocidos en vez de difundirlas por el aire). No afecta el rastreo por MAC de <code>uhotspot</code>.</li>
        <li><b>No</b> activar 2FA en la cuenta — de lo contrario <code>uhotspotd</code> no podrá autenticarse contra la API de UniFi.</li>
        <li><b>Nombre del sitio</b>: si el admin renombró el sitio UniFi desde <code>default</code>, debe actualizar <code>UNIFI_SITE</code> en <code>/etc/uhotspot/uhotspot.conf</code>.</li>
        <li><b>Si el host del controlador tiene dos NICs</b> (WAN + LAN), defina <code>system_ip</code> en <code>/var/lib/unifi/system.properties</code> con la IP LAN y reinicie UniFi.</li>
        <li><b>APs Wi-Fi 7</b>: desactivar <i>MLO (Multi-Link Operation)</i> en el SSID de invitados. El estándar IEEE 802.11be define una dirección Multi-Link Device (MLD) distinta de la MAC propia de cada enlace físico — como <code>uhotspot</code> rastrea y autoriza clientes estrictamente por MAC (reservas DHCP estáticas, API de UniFi, iptables/ipset), un cliente MLO podría verse de forma inconsistente entre esas capas. Es una característica del estándar Wi-Fi 7, no un bug específico de UniFi.</li>
      </ol>
    </td>
  </tr>
</table>

## SETUP

---

### Install

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Clone the repository with <code>git clone</code> and run the installer. <code>usetup.sh</code> handles dependency verification, DHCP backend detection, file deployment, interactive setup wizard (interfaces, IPs, range, SSID, UniFi credentials, controller auto-discovery, optional managed MAC lists), logrotate config, systemd service registration, and cleanup of any stale <code>@hourly</code> cron entry from installs done before the daemon handled its own safety-net reload. Make sure every item in <a href="#minimum-requirements">Minimum Requirements</a> and <a href="#dependencies">Dependencies</a> is in place <b>before</b> running the installer — none of it is installed automatically, and <code>pydhcp</code> must already be running.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Clone el repositorio con <code>git clone</code> y ejecute el instalador. <code>usetup.sh</code> se encarga de verificar dependencias, detectar el backend DHCP, desplegar archivos, correr el wizard interactivo (interfaces, IPs, rango, SSID, credenciales UniFi, autodescubrimiento del controlador, listas opcionales de MACs gestionadas), configurar logrotate, registrar el servicio systemd y limpiar cualquier entrada de cron <code>@hourly</code> residual de instalaciones anteriores a que el daemon manejara su propio reload de seguridad. Asegúrese de tener listos, <b>antes</b> de ejecutar el instalador, todo lo de <a href="#minimum-requirements">Minimum Requirements</a> y <a href="#dependencies">Dependencies</a> — nada se instala automáticamente, y <code>pydhcp</code> ya debe estar corriendo.
    </td>
  </tr>
</table>

```bash
git clone --depth=1 https://github.com/maravento/uhotspot.git
cd uhotspot
sudo bash usetup.sh
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The installer checks for required apt dependencies (<code>curl</code>, <code>jq</code>, <code>iptables</code>, <code>ipset</code>, <code>cron</code>, <code>python3</code>) and aborts if any is missing — none of them are installed automatically. It also aborts if <code>pydhcp</code> is not active. It deploys <code>uhotspotd.sh</code>, <code>ureload.sh</code> and <code>uleases.sh</code> to <code>/etc/uhotspot/core/</code>, the optional tools to <code>/etc/uhotspot/tools/</code>, installs <code>uhotspotd.service</code> to <code>/etc/systemd/system/</code>, and enables and starts the daemon via <code>systemctl enable</code> + <code>restart uhotspotd</code>. No files are copied to <code>/etc/pydhcp</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      El instalador verifica las dependencias apt requeridas (<code>curl</code>, <code>jq</code>, <code>iptables</code>, <code>ipset</code>, <code>cron</code>, <code>python3</code>) y aborta si falta alguna — ninguna se instala automáticamente. También aborta si <code>pydhcp</code> no está activo. Despliega <code>uhotspotd.sh</code>, <code>ureload.sh</code> y <code>uleases.sh</code> en <code>/etc/uhotspot/core/</code>, las herramientas opcionales en <code>/etc/uhotspot/tools/</code>, instala <code>uhotspotd.service</code> en <code>/etc/systemd/system/</code> y habilita e inicia el daemon con <code>systemctl enable</code> + <code>restart uhotspotd</code>. No se copian archivos a <code>/etc/pydhcp</code>.
    </td>
  </tr>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The systemd service drives the main hotspot loop (every <code>POLL_INTERVAL</code> seconds, default 20, set in <code>uhotspot.conf</code>). No crontab entry is registered — the daemon triggers its own safety-net reload internally (see below).
    </td>
    <td style="width: 50%; vertical-align: top;">
      El servicio systemd conduce el ciclo principal del hotspot (cada <code>POLL_INTERVAL</code> segundos, default 20, configurado en <code>uhotspot.conf</code>). No se registra ninguna entrada de crontab — el daemon dispara su propio reload de seguridad internamente (ver abajo).
    </td>
  </tr>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Purpose:</b> keep the ACL lists up to date and the reload chain active even during periods of no client activity. Every cycle, <code>uhotspotd.sh</code> forces a reload — regardless of whether any ACL file changed — if more than <code>RELOAD_SAFETY_INTERVAL_SECONDS</code> (default 3600, one hour) have passed since the last one, so expired grace entries still get promoted to <code>blockdhcp.txt</code> even on idle networks where no new client would otherwise trigger a reload. <code>uhotspotd.sh</code> is the only caller of <code>ureload.sh</code> — no external cron entry is registered — so there is no possibility of two independent callers racing for <code>ureload.sh</code>'s own instance lock.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Propósito:</b> mantener las listas ACL actualizadas y la cadena de reload activa incluso en periodos sin actividad de clientes. En cada ciclo, <code>uhotspotd.sh</code> fuerza un reload — sin importar si alguna ACL cambió — si pasaron más de <code>RELOAD_SAFETY_INTERVAL_SECONDS</code> (default 3600, una hora) desde el último, para que las entradas de gracia expiradas se promuevan a <code>blockdhcp.txt</code> incluso en redes inactivas donde ningún cliente nuevo dispararía un reload. <code>uhotspotd.sh</code> es el único invocador de <code>ureload.sh</code> — no se registra ninguna entrada de cron externa — así que no existe posibilidad de que dos invocadores independientes compitan por el lock de instancia de <code>ureload.sh</code>.
    </td>
  </tr>
</table>

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Verify the daemon status with:
    </td>
    <td style="width: 50%; vertical-align: top;">
      Verifique el estado del daemon con:
    </td>
  </tr>
</table>

```bash
systemctl status uhotspotd
journalctl -u uhotspotd -f
```

### Update

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      To update scripts while never touching existing configuration or ACL data:
      <ul>
        <li>Updates: <code>uhotspotd.sh</code>, <code>uhotspotd.service</code>, <code>ureload.sh</code>, <code>uleases.sh</code>, and every script under <code>tools/</code> (<code>uaudit.sh</code>, <code>ucheck.sh</code>, <code>ualert.sh</code>, <code>uwatch.sh</code>, <code>uhotspotmon.sh</code>) — <code>tools/uiptables_example.sh</code> is a reference template, never deployed</li>
        <li>Never renamed, moved or overwritten if already present: <code>uhotspot.conf</code>, <code>/etc/uhotspot/acl/</code> (<code>umacauth.txt</code>, <code>umacbak.txt</code>, <code>uqueue.txt</code>, <code>ugrace.txt</code>), <code>tools/uiptables.sh</code> if it exists, and the logrotate config — they are the administrator's own live/customized data. Any of these that is missing (e.g. a partial/broken install) is created empty with a WARNING, so the daemon never fails to start over a missing file; existing ones are left exactly as they are</li>
        <li><b>Pauses services before replacing their scripts, resumes them after:</b> <code>uhotspotd.service</code> and <code>ualert.service</code> (if installed) are stopped — only if they were actually active — before any file is overwritten, and restarted once the update finishes; <code>uwatch</code>'s cron entry (not a systemd service) is commented out for the same window and uncommented afterward. Nothing that was already stopped/disabled beforehand is started. <code>pydhcpd</code> is deliberately left alone — it's a separate project this update never touches, and stopping it would cut DHCP for the whole LAN, not just the hotspot</li>
        <li>Removes any stale <code>@hourly</code> ureload.sh cron entry (superseded by the daemon's own safety-net reload)</li>
        <li>Creates a timestamped backup of current scripts before overwriting</li>
      </ul>
     </td>
    <td style="width: 50%; vertical-align: top;">
      Para actualizar los scripts sin tocar nunca la configuración ni los datos ACL ya existentes:
      <ul>
        <li>Actualiza: <code>uhotspotd.sh</code>, <code>uhotspotd.service</code>, <code>ureload.sh</code>, <code>uleases.sh</code>, y todos los scripts de <code>tools/</code> (<code>uaudit.sh</code>, <code>ucheck.sh</code>, <code>ualert.sh</code>, <code>uwatch.sh</code>, <code>uhotspotmon.sh</code>) — <code>tools/uiptables_example.sh</code> es una plantilla de referencia, nunca se despliega</li>
        <li>Nunca se renombran, mueven ni sobrescriben si ya existen: <code>uhotspot.conf</code>, <code>/etc/uhotspot/acl/</code> (<code>umacauth.txt</code>, <code>umacbak.txt</code>, <code>uqueue.txt</code>, <code>ugrace.txt</code>), <code>tools/uiptables.sh</code> si existe, ni la configuración de logrotate — son datos propios y personalizados del administrador. Cualquiera de estos que falte (ej. una instalación parcial/rota) se crea vacío con un WARNING, para que el daemon nunca deje de arrancar por un archivo faltante; los que ya existen quedan exactamente como estaban</li>
        <li><b>Pausa los servicios antes de reemplazar sus scripts, los reanuda al terminar:</b> <code>uhotspotd.service</code> y <code>ualert.service</code> (si está instalado) se detienen — solo si estaban activos — antes de sobrescribir cualquier archivo, y se reinician al finalizar la actualización; la entrada de cron de <code>uwatch</code> (no es un servicio systemd) se comenta durante esa misma ventana y se descomenta después. Nada que ya estuviera detenido/desactivado de antemano se inicia. <code>pydhcpd</code> se deja intencionalmente en paz — es un proyecto aparte que esta actualización nunca toca, y detenerlo cortaría el DHCP de toda la LAN, no solo del hotspot</li>
        <li>Elimina cualquier entrada de cron <code>@hourly</code> de ureload.sh residual (reemplazada por el reload de seguridad interno del daemon)</li>
        <li>Crea un backup con timestamp de los scripts actuales antes de sobrescribir</li>
      </ul>
     </td>
  </tr>
</table>

```bash
cd uhotspot
sudo bash usetup.sh --update
```

### Remove

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The installer also supports interactive uninstall. Each destructive step requires explicit confirmation (default <i>No</i>); firewall rules and ipsets are <b>not</b> touched — you must flush them manually as documented at the end of the removal summary.
    </td>
    <td style="width: 50%; vertical-align: top;">
      El instalador también soporta desinstalación interactiva. Cada paso destructivo requiere confirmación explícita (default <i>No</i>); las reglas de firewall y los ipsets <b>no</b> se tocan — debe limpiarlos manualmente como se documenta al final del resumen de remoción.
    </td>
  </tr>
</table>

```bash
cd uhotspot
sudo bash usetup.sh --remove
```

##### Uninstaller actions

| # | Description (each requires individual y/N confirmation) | Descripción (cada una requiere confirmación y/N individual) |
|---|-----------------------------------------------------------|---------------------------------------------------------------|
| 1 | Stop and disable `uhotspotd.service` and remove `/etc/systemd/system/uhotspotd.service` | Detiene y deshabilita `uhotspotd.service` y elimina `/etc/systemd/system/uhotspotd.service` |
| 2 | Remove the `@hourly` cron entry for `/etc/uhotspot/core/ureload.sh` (or the pre-restructure `/etc/uhotspot/tools/ureload.sh` path, if upgrading from an older install) | Elimina la entrada de cron `@hourly` para `/etc/uhotspot/core/ureload.sh` (o la ruta previa a la reestructuración `/etc/uhotspot/tools/ureload.sh`, si se actualiza desde una instalación anterior) |
| 3 | Remove `/etc/logrotate.d/uhotspot` | Elimina `/etc/logrotate.d/uhotspot` |
| 4 | Remove `/etc/uhotspot/` and **all its contents** including `uhotspot.conf`, ACL files, and your `uiptables.sh` | Elimina `/etc/uhotspot/` y **todo su contenido**, incluyendo `uhotspot.conf`, archivos ACL y su `uiptables.sh` |
| 5 | Remove `/var/log/uhotspot.log` and rotated archives | Elimina `/var/log/uhotspot.log` y los archivos rotados |

### Files

| Description | Descripción | Path |
|---|---|---|
| Main daemon | Daemon principal | `/etc/uhotspot/core/uhotspotd.sh` |
| Systemd service unit | Unidad de servicio systemd | `/etc/systemd/system/uhotspotd.service` |
| Reload wrapper | Wrapper de reload | `/etc/uhotspot/core/ureload.sh` |
| Hotspot-aware DHCP leases manager | Gestor de leases DHCP con hotspot | `/etc/uhotspot/core/uleases.sh` |
| Audit tool | Herramienta de auditoría | `/etc/uhotspot/tools/uaudit.sh` |
| Configuration (interfaces, IPs, credentials, ports) | Configuración | `/etc/uhotspot/uhotspot.conf` |
| Grace-period clients (no voucher yet) | Clientes en período de gracia | `/etc/uhotspot/acl/ugrace.txt` |
| Authorized clients (active voucher) | Autorizados | `/etc/uhotspot/acl/umacauth.txt` |
| Cumulative MAC backup (one MAC per line) | Backup acumulativo de MACs | `/etc/uhotspot/acl/umacbak.txt` |
| Lease removal queue — internal working file for `uhotspotd.sh`/`uleases.sh`, not a config variable or ACL; do not edit manually | Cola de remociones de leases — archivo de trabajo interno de `uhotspotd.sh`/`uleases.sh`, no es variable de configuración ni ACL; no debe editarse manualmente | `/etc/uhotspot/acl/uqueue.txt` |
| Log file (unified) | Archivo de log (unificado) | `/var/log/uhotspot.log` |
| Logrotate config | Config de logrotate | `/etc/logrotate.d/uhotspot` |
| Webmin log viewer module | Módulo visor de log para Webmin | `/etc/uhotspot/tools/uhotspotmon.sh` |

### Config Reference (uhotspot.conf)

| Variable | Description | Descripción |
|----------|--------------|-------------|
| `WAN_IF`, `LAN_IF` | Interface names validated against `ip link` during setup | Nombres de interfaz validados contra `ip link` durante la instalación |
| `SERVER_IP` | This machine's IP on the LAN | IP de esta máquina en la LAN |
| `LOCAL_USER` | Local Linux user (auto-detected) | Usuario Linux local (detectado automáticamente) |
| `HOTSPOT_IP_RANGE` | First three octets of the hotspot pool, auto-derived from `SERVER_IP` | Primeros tres octetos del pool del hotspot, derivado automáticamente de `SERVER_IP` |
| `HOTSPOT_RANGE_START`, `HOTSPOT_RANGE_END` | Last-octet bounds of the pool | Límites del último octeto del pool |
| `HOTSPOT_ESSID` | Guest SSID name; must match UniFi exactly | Nombre del SSID de invitados; debe coincidir exactamente con UniFi |
| `UNIFI_CONTROLLER_URL` | e.g. `https://192.168.1.1:8443` | ej. `https://192.168.1.1:8443` |
| `UNIFI_USERNAME`, `UNIFI_PASSWORD` | Local UniFi admin | Admin local de UniFi |
| `UNIFI_SITE` | Defaults to `default`; update if the site was renamed | Por defecto `default`; actualizar si el sitio fue renombrado |
| `UNIFI_TYPE` | Either `unifi-os` or `classic` — sets the API path, login endpoint, session cookie name, and CSRF extraction method used by `uhotspotd.sh` | `unifi-os` o `classic` — define la ruta de la API, el endpoint de login, el nombre de la cookie de sesión y el método de extracción de CSRF que usa `uhotspotd.sh` |
| `SERVER_RELOAD_SCRIPT` | Path to `ureload.sh` | Ruta a `ureload.sh` |
| `SERV_DHCP` | DHCP server IP (same as `SERVER_IP`; used by `uleases.sh` and `uiptables.sh`) | IP del servidor DHCP (igual a `SERVER_IP`; usado por `uleases.sh` y `uiptables.sh`) |
| `SERV_MASK` | Network mask (default `255.255.255.0`) | Máscara de red (default `255.255.255.0`) |
| `SERV_SUBNET` | Network address, derived from `SERVER_IP`/`SERV_MASK` (default `192.168.0.0`) | Dirección de red, derivada de `SERVER_IP`/`SERV_MASK` (default `192.168.0.0`) |
| `SERV_BROADCAST` | Broadcast address, derived from `SERVER_IP`/`SERV_MASK` (default `192.168.0.255`) | Dirección de broadcast, derivada de `SERVER_IP`/`SERV_MASK` (default `192.168.0.255`) |
| `SERV_DNS` | DNS servers for clients, comma-separated (default `8.8.8.8,1.1.1.1`) | Servidores DNS para clientes, separados por coma (default `8.8.8.8,1.1.1.1`) |
| `SERV_INI_RANGE_BLOCK`, `SERV_END_RANGE_BLOCK` | DHCP pool range for new/unknown clients (default `192.168.0.230`–`192.168.0.239`) | Rango del pool DHCP para clientes nuevos/desconocidos (default `192.168.0.230`–`192.168.0.239`) |
| `ACL_PATH` | Base ACL directory (default `/etc/acl`) | Directorio base de ACL (default `/etc/acl`) |
| `ACL_MAC_PATH` | Managed MAC lists directory (default `/etc/acl/acl_mac`) | Directorio de listas de MAC gestionadas (default `/etc/acl/acl_mac`) |
| `ACL_DHCP_PATH` | DHCP-related ACL files directory (default `/etc/acl/acl_dhcp`) | Directorio de archivos ACL relacionados con DHCP (default `/etc/acl/acl_dhcp`) |
| `HOTSPOT_PATH` | uhotspot installation/data directory (default `/etc/uhotspot`) | Directorio de instalación/datos de uhotspot (default `/etc/uhotspot`) |
| `ACL_MAC_PROXY` | Managed proxy MAC list (default `/etc/acl/acl_mac/mac-proxy.txt`) | Lista de MAC gestionadas forzadas por proxy (default `/etc/acl/acl_mac/mac-proxy.txt`) |
| `ACL_MAC_UNLIMITED` | Managed unrestricted MAC list (default `/etc/acl/acl_mac/mac-unlimited.txt`) | Lista de MAC gestionadas sin restricciones (default `/etc/acl/acl_mac/mac-unlimited.txt`) |
| `ACL_MAC_HOTSPOT` | Active hotspot-authorized MAC list (default `/etc/uhotspot/acl/umacauth.txt`) | Lista de MAC autorizadas activas del hotspot (default `/etc/uhotspot/acl/umacauth.txt`) |
| `ACL_BLOCK_FILE` | Permanently blocked MAC list (default `/etc/acl/acl_dhcp/blockdhcp.txt`) | Lista de MAC bloqueadas permanentemente (default `/etc/acl/acl_dhcp/blockdhcp.txt`) |
| `ACL_GRACE_FILE` | Grace-period MAC list (default `/etc/uhotspot/acl/ugrace.txt`) | Lista de MAC en período de gracia (default `/etc/uhotspot/acl/ugrace.txt`) |
| `POLL_INTERVAL` | Daemon cycle interval in seconds (default `20`) | Intervalo del ciclo del daemon en segundos (default `20`) |
| `RELOAD_SAFETY_INTERVAL_SECONDS` | Force a reload even without an ACL change after this many seconds (default `3600` = 1h) | Fuerza un reload aunque no haya cambio de ACL tras esta cantidad de segundos (default `3600` = 1h) |
| `STARTUP_GRACE_SECONDS` | Grace window (seconds) for the initial UniFi login retry and for suppressing `ualert.sh` connectivity alerts right after startup (default `120`) | Ventana de gracia (segundos) para el reintento inicial de login a UniFi y para suprimir alertas de conectividad de `ualert.sh` justo después de arrancar (default `120`) |
| `CLEANUP_INTERVAL` | DHCP pool lease time in seconds (default `60`) | Tiempo de lease del pool DHCP en segundos (default `60`) |
| `AUTHORIZED_LEASE_TIME` | DHCP lease time for authorized clients in seconds (default `2592000` = 30 days) | Tiempo de lease DHCP para clientes autorizados en segundos (default `2592000` = 30 días) |
| `BLOCKDHCP_GRACE_SECONDS` | Grace period before unknown MACs are blocked (default `86400` = 24h) | Período de gracia antes de bloquear MACs desconocidas (default `86400` = 24h) |
| `UNIFI_HOTSPOT_ENABLED` | Set `false` only for testing without a UniFi controller (default `true`) | Configurar en `false` solo para pruebas sin un controlador UniFi (default `true`) |
| `WPAD_ENABLED` | `true` to enable WPAD/PAC via DHCP option 252, requires Apache2 on port 18100 (default `false`) | `true` para habilitar WPAD/PAC vía la opción DHCP 252, requiere Apache2 en el puerto 18100 (default `false`) |
| `PING_CHECK_ENABLED` | `false` to disable pydhcpd ping-check before OFFER, set if ICMP is blocked (default `true`) | `false` para deshabilitar el ping-check de pydhcpd antes del OFFER, usar si ICMP está bloqueado (default `true`) |

> Every variable above that isn't strictly required (network/UniFi credentials) falls back to the default shown if missing from `uhotspot.conf` — scripts never fail silently or use an undocumented value.
>
> Toda variable de arriba que no sea estrictamente requerida (red/credenciales UniFi) usa el default mostrado si falta en `uhotspot.conf` — los scripts nunca fallan en silencio ni usan un valor no documentado.

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Example <code>/etc/uhotspot/uhotspot.conf</code></b> (as written by <code>usetup.sh</code>; <code>ualert.sh install</code> appends the last block):
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Ejemplo de <code>/etc/uhotspot/uhotspot.conf</code></b> (como lo escribe <code>usetup.sh</code>; <code>ualert.sh install</code> agrega el último bloque):
    </td>
  </tr>
</table>

```bash
# uhotspot — auto-generated by usetup.sh on 2026-06-25 14:32:10
# Edit this file to adjust any value.

# ── Network ──────────────────────────────────────────────────────────────────
WAN_IF="eno1"
LAN_IF="eno2"
SERVER_IP="192.168.0.10"
LOCAL_USER="myuser"

# ── Hotspot IP range ─────────────────────────────────────────────────────────
HOTSPOT_IP_RANGE="192.168.0"
HOTSPOT_RANGE_START=180
HOTSPOT_RANGE_END=220

# ── Guest SSID ───────────────────────────────────────────────────────────────
HOTSPOT_ESSID="EXAMPLE_SSID"

# ── UniFi Controller ─────────────────────────────────────────────────────────
UNIFI_CONTROLLER_URL="https://192.168.0.10:11443"
UNIFI_USERNAME="admin"
UNIFI_PASSWORD="mypass"
UNIFI_SITE="default"
UNIFI_TYPE="unifi-os"

# ── Reload script (required) ─────────────────────────────────────────────────
SERVER_RELOAD_SCRIPT="/etc/uhotspot/core/ureload.sh"

# ── DHCP network (read by uleases.sh and uiptables.sh) ───────────────────────
SERV_DHCP=192.168.0.10
SERV_MASK=255.255.255.0
SERV_SUBNET=192.168.0.0
SERV_BROADCAST=192.168.0.255
SERV_DNS=8.8.8.8,1.1.1.1

# ── DHCP pool (temporary IPs for new/unknown clients) ────────────────────────
SERV_INI_RANGE_BLOCK=192.168.0.230
SERV_END_RANGE_BLOCK=192.168.0.239

# ── Paths (read by uleases.sh) ───────────────────────────────────────────────
ACL_PATH=/etc/acl
ACL_MAC_PATH=/etc/acl/acl_mac
ACL_DHCP_PATH=/etc/acl/acl_dhcp
ACL_MAC_PROXY=/etc/acl/acl_mac/mac-proxy.txt
ACL_MAC_UNLIMITED=/etc/acl/acl_mac/mac-unlimited.txt
ACL_BLOCK_FILE=/etc/acl/acl_dhcp/blockdhcp.txt
ACL_GRACE_FILE=/etc/uhotspot/acl/ugrace.txt
ACL_MAC_HOTSPOT=/etc/uhotspot/acl/umacauth.txt

# ── Daemon & DHCP timers ─────────────────────────────────────────────────────
POLL_INTERVAL=20
CLEANUP_INTERVAL=60
AUTHORIZED_LEASE_TIME=2592000
BLOCKDHCP_GRACE_SECONDS=86400

# ── Optional features ────────────────────────────────────────────────────────
UNIFI_HOTSPOT_ENABLED=true
WPAD_ENABLED=true
PING_CHECK_ENABLED=true

# ── Alert ────────────────────────────────────────────────────────────────────
NTFY_TOPIC="uhotspot-alert-x7k2m9qv"
API_FAIL_THRESHOLD=3
STARTUP_GRACE_SECONDS=120
```

### Webmin Module

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>uhotspotmon.sh</code> installs a native Webmin module (<b>Networking → UniFi Hotspot Log Viewer</b>) that replaces <code>tail -f</code> for monitoring <code>/var/log/uhotspot.log</code>. It uses AJAX byte-offset polling — reading only new bytes since the last position — so it never stalls on log rotation. The module is written as a self-contained bash installer following the same pattern as <code>servicemon.sh</code> and <code>squidmon.sh</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>uhotspotmon.sh</code> instala un módulo nativo de Webmin (<b>Networking → UniFi Hotspot Log Viewer</b>) que reemplaza a <code>tail -f</code> para monitorear <code>/var/log/uhotspot.log</code>. Usa polling AJAX por byte offset — leyendo solo los bytes nuevos desde la última posición — así nunca se atasca con la rotación de logs. El módulo está escrito como un instalador bash autocontenido siguiendo el mismo patrón que <code>servicemon.sh</code> y <code>squidmon.sh</code>.
    </td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><b>Light</b></td>
    <td align="center"><b>Dark</b></td>
  </tr>
  <tr>
    <td><a href="https://github.com/maravento/uhotspot"><img src="https://raw.githubusercontent.com/maravento/uhotspot/master/img/uhotspotview1.png" width="100%"></a></td>
    <td><a href="https://github.com/maravento/uhotspot"><img src="https://raw.githubusercontent.com/maravento/uhotspot/master/img/uhotspotview2.png" width="100%"></a></td>
  </tr>
</table>

##### Features

| Feature | Description | Descripción |
|---------|--------------|-------------|
| **Live polling** | AJAX polling by byte offset (1s–30s configurable). Never stalls on log rotation. | Polling AJAX por byte offset (1s–30s configurable). No se atasca con la rotación de logs. |
| **Dark / Light mode** | Toggle with moon/sun button. Preference saved in `localStorage`. | Alternancia con botón luna/sol. Preferencia guardada en `localStorage`. |
| **Level badges** | Color-coded badges: INFO (blue), WARNING (amber), ERROR (red), RELOAD (grey). | Badges con color: INFO (azul), WARNING (ámbar), ERROR (rojo), RELOAD (gris). |
| **Full-log grep** | Searches the entire log file via `grep -Fia`. Results highlighted inline. | Busca en el archivo completo vía `grep -Fia`. Resultados resaltados inline. |
| **Cycle stats bar** | Parses the last stats line and shows Vouchers, Authorized, Grace, New Auth, Revoked, Managed as pills. | Parsea la última línea de stats y muestra Vouchers, Authorized, Grace, New Auth, Revoked, Managed como pills. |
| **Service status** | Shows PID, uptime, and memory from `systemctl status uhotspotd`. | Muestra PID, uptime y memoria desde `systemctl status uhotspotd`. |
| **Text filter** | Live filter on visible rows (regex-compatible). | Filtro en vivo sobre filas visibles (compatible con regex). |
| **Level filter** | Dropdown to show only INFO / WARNING / ERROR / RELOAD. | Dropdown para mostrar solo INFO / WARNING / ERROR / RELOAD. |
| **Configurable** | Log file path editable from Webmin module config (gear icon). | Ruta del log editable desde la configuración del módulo Webmin (icono engranaje). |

```bash
# Install
sudo bash tools/uhotspotmon.sh install

# Uninstall
sudo bash tools/uhotspotmon.sh uninstall
```

> Requires Webmin installed (`/usr/share/webmin`). After install, log out and back into Webmin. The module appears under **Networking**.
>
> Requiere Webmin instalado (`/usr/share/webmin`). Tras instalar, hacer logout y login en Webmin. El módulo aparece bajo **Networking**.

### Reconfigure

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      To reconfigure, edit <code>/etc/uhotspot/uhotspot.conf</code> directly. To start over from scratch, remove the config file and re-run the installer.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Para reconfigurar, edite <code>/etc/uhotspot/uhotspot.conf</code> directamente. Para empezar de cero, elimine el archivo de config y vuelva a ejecutar el instalador.
    </td>
  </tr>
</table>

```bash
# Edit any value (credentials, interfaces, range, ports, SSID, etc.)
sudo nano /etc/uhotspot/uhotspot.conf

# Or: force a fresh interactive setup
sudo rm /etc/uhotspot/uhotspot.conf
cd uhotspot && sudo bash usetup.sh
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      (For full uninstall, see the <a href="#remove">Remove</a> section above.)
    </td>
    <td style="width: 50%; vertical-align: top;">
      (Para desinstalar por completo, vea la sección <a href="#remove">Remove</a> más arriba.)
    </td>
  </tr>
</table>

## HOW IT WORKS

---

### Daemon Cycle

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The daemon executes a full cycle every <code>POLL_INTERVAL</code> seconds (default 20, configured in <code>uhotspot.conf</code>). Each cycle executes eleven steps, plus one independent mechanism that isn't a numbered step (see below):
      <ol>
        <li><b>vouchers</b> — loads the full voucher list from UniFi (<code>stat/voucher</code>) into an in-memory cache shared by the sessions step.</li>
        <li><b>snapshot</b> — captures md5 baselines of the ACL files before any modification. Taken before <b>dedup</b> so that step's <code>blockdhcp.txt</code> changes are detected as a real ACL change by the reload step below.</li>
        <li><b>dedup</b> — cross-list consistency check between <code>umacauth.txt</code> and <code>blockdhcp.txt</code> only: removes any MAC from <code>blockdhcp.txt</code> that also appears in <code>umacauth.txt</code>, and sanitizes malformed <code>blockdhcp.txt</code> lines. Never reads <code>mac-*.txt</code> content (see Managed MAC lists below).</li>
        <li><b>sort</b> — sorts and deduplicates <code>umacauth.txt</code> by IP.</li>
        <li><b>expire</b> — for each entry in <code>umacauth.txt</code> whose <code>END_TIME_EPOCH</code> is in the past, release it: queue a lease removal for <code>uleases.sh</code> and remove it from the file. The MAC is preserved in <code>umacbak.txt</code> by the backup step.</li>
        <li><b>new leases</b> — scans <code>pydhcpd.leases</code> directly. Any MAC not yet present in <code>umacauth.txt</code>, <code>blockdhcp.txt</code>, <code>ugrace.txt</code>, or <code>umacbak.txt</code> is written straight into <code>ugrace.txt</code> with a first-seen timestamp. No fixed hotspot-range IP is assigned and no lease removal is queued — the client keeps its existing pool lease. This is the step that makes new clients visible; writing <code>ugrace.txt</code> is what triggers the reload step below. A managed device's lease can transiently land here too (this step doesn't check <code>mac-*.txt</code> either) — <code>uleases.sh</code>'s <code>clean_grace_list</code> reconciles it back out on the very next reload.</li>
        <li><b>sessions</b> — query <code>stat/guest</code>, filter by <code>end &gt; now</code> (the <code>expired==false</code> flag is unreliable in UniFi). For each authenticated client not yet in <code>umacauth.txt</code>, assign the next free hotspot-range IP with hostname <code>guest{N}-{voucher_code}</code>. Skips any MAC listed in <code>mac-*.txt</code> (active or commented, checked live against disk) — a guard against a stale or externally-granted UniFi guest authorization for a managed device.</li>
        <li><b>revoke</b> — query <code>stat/sta</code>; for each MAC in <code>umacauth.txt</code> that UniFi reports with <code>authorized=false</code>, remove it from <code>umacauth.txt</code> and queue a lease removal.</li>
        <li><b>backup</b> — append (add-only, never remove) every MAC in <code>umacauth.txt</code> to <code>umacbak.txt</code>; remove from <code>blockdhcp.txt</code> any MAC also in <code>umacbak.txt</code> (protects previously-authenticated clients from being permanently blocked).</li>
        <li><b>reload</b> — compare md5 against baseline, including <code>ugrace.txt</code>, OR a <code>mac-*.txt</code> change flagged by the independent watcher (below) last cycle. If anything changed, or if more than <code>RELOAD_SAFETY_INTERVAL_SECONDS</code> (default one hour) passed since the last reload, invoke <code>SERVER_RELOAD_SCRIPT</code> with a 60s timeout (which runs <code>uleases.sh</code>) — a single invocation covers both triggers if they coincide. The safety-net path is what promotes expired grace entries to <code>blockdhcp.txt</code> on idle networks where no new client would otherwise trigger a reload. If nothing is due, nothing is logged — the daemon stays silent on no-op cycles, by design (see LOGS section below).</li>
        <li><b>kick</b> — for each MAC newly promoted to <code>umacauth.txt</code> this cycle that's still connected (checked against <code>stat/sta</code>), force a disassociation via <code>kick-sta</code> so the client reconnects immediately with its new fixed IP instead of racing its stale pool lease. Also skips any <code>mac-*.txt</code> MAC, as defense-in-depth (structurally unreachable here, since step 7 already excludes them).</li>
      </ol>
      <b>mac-*.txt change watcher</b> (independent, not a numbered step): every cycle, right after <b>snapshot</b>, fingerprints all <code>mac-*.txt</code> files with a combined md5 (existence + content, no MAC/status parsing) and compares it to the previous cycle's. If it changed, the reload isn't triggered immediately — it's flagged for the <b>reload</b> step to pick up next cycle, so it never causes a second, separate <code>ureload.sh</code> invocation in the same run as one already triggered by the ACL files above.
      <br><br>
      This is why an edit always produces <b>two</b> log lines, one cycle apart, not one — they mark two different moments, not a duplicate:
      <code>2026-07-23 22:01:28 INFO: mac-*.txt changed -- reload scheduled for next cycle</code><br>
      <code>2026-07-23 22:01:31 INFO: mac-*.txt change from previous cycle -- reloading now</code><br>
      <code>2026-07-23 22:01:31 INFO: invoking /etc/uhotspot/core/ureload.sh</code>
      <br><br>
      The first line is the watcher noticing the change (this cycle); the second is the reload step actually acting on it (next cycle), immediately followed by the actual invocation. Seeing only the first without a follow-up second line one cycle later would itself be a sign something is wrong.
    </td>
    <td style="width: 50%; vertical-align: top;">
      El daemon ejecuta un ciclo completo cada <code>POLL_INTERVAL</code> segundos (default 20, configurado en <code>uhotspot.conf</code>). Cada ciclo ejecuta once pasos, más un mecanismo independiente que no es un paso numerado (ver abajo):
      <ol>
        <li><b>vouchers</b> — carga la lista completa de vouchers desde UniFi (<code>stat/voucher</code>) en una caché en memoria compartida por el paso sessions.</li>
        <li><b>snapshot</b> — captura md5 baseline de los archivos ACL antes de cualquier modificación. Se toma antes de <b>dedup</b> para que los cambios de ese paso en <code>blockdhcp.txt</code> sean detectados como un cambio real de ACL por el paso de reload.</li>
        <li><b>dedup</b> — chequeo de consistencia solo entre <code>umacauth.txt</code> y <code>blockdhcp.txt</code>: elimina de <code>blockdhcp.txt</code> cualquier MAC que también aparezca en <code>umacauth.txt</code>, y sanea líneas malformadas de <code>blockdhcp.txt</code>. Nunca lee el contenido de <code>mac-*.txt</code> (ver Listas de MACs gestionadas más abajo).</li>
        <li><b>sort</b> — ordena y deduplica <code>umacauth.txt</code> por IP.</li>
        <li><b>expire</b> — para cada entrada en <code>umacauth.txt</code> cuyo <code>END_TIME_EPOCH</code> ya pasó, la libera: encola una remoción de lease para <code>uleases.sh</code> y la elimina del archivo. La MAC queda preservada en <code>umacbak.txt</code> por el paso backup.</li>
        <li><b>clientes nuevos</b> — escanea <code>pydhcpd.leases</code> directamente. Cualquier MAC que aún no esté en <code>umacauth.txt</code>, <code>blockdhcp.txt</code>, <code>ugrace.txt</code> ni <code>umacbak.txt</code> se escribe directo en <code>ugrace.txt</code> con un timestamp de primer contacto. No se asigna IP fija del rango hotspot ni se encola remoción de lease — el cliente conserva el lease de pool que ya tenía. Este es el paso que hace visibles a los clientes nuevos; escribir <code>ugrace.txt</code> es lo que dispara el paso de reload más abajo. El lease de un dispositivo gestionado puede caer aquí transitoriamente también (este paso tampoco revisa <code>mac-*.txt</code>) — <code>clean_grace_list</code> de <code>uleases.sh</code> lo reconcilia en el siguiente reload.</li>
        <li><b>sessions</b> — consulta <code>stat/guest</code>, filtra por <code>end &gt; now</code> (el flag <code>expired==false</code> no es confiable en UniFi). Para cada cliente autenticado que aún no esté en <code>umacauth.txt</code>, asigna la siguiente IP libre del rango hotspot con hostname <code>guest{N}-{codigo_voucher}</code>. Salta cualquier MAC listada en <code>mac-*.txt</code> (activa o comentada, comprobado en vivo contra el disco) — una barrera contra una autorización de invitado en UniFi residual o concedida fuera del daemon para un dispositivo gestionado.</li>
        <li><b>revoke</b> — consulta <code>stat/sta</code>; para cada MAC en <code>umacauth.txt</code> que UniFi reporta con <code>authorized=false</code>, la elimina de <code>umacauth.txt</code> y encola una remoción de lease.</li>
        <li><b>backup</b> — añade (solo agregar, nunca remover) cada MAC de <code>umacauth.txt</code> a <code>umacbak.txt</code>; elimina de <code>blockdhcp.txt</code> cualquier MAC también en <code>umacbak.txt</code> (protege a clientes anteriormente autenticados de ser bloqueados permanentemente).</li>
        <li><b>reload</b> — compara md5 contra baseline, incluyendo <code>ugrace.txt</code>, O un cambio en <code>mac-*.txt</code> marcado por el watcher independiente (abajo) en el ciclo anterior. Si algo cambió, o si pasó más de <code>RELOAD_SAFETY_INTERVAL_SECONDS</code> (default una hora) desde el último reload, invoca <code>SERVER_RELOAD_SCRIPT</code> con timeout de 60s (que a su vez ejecuta <code>uleases.sh</code>) — una sola invocación cubre ambos disparadores si coinciden. El camino de seguridad es el que promueve entradas de gracia expiradas a <code>blockdhcp.txt</code> en redes inactivas donde ningún cliente nuevo dispararía un reload. Si no hay nada pendiente, no se registra nada — el daemon permanece en silencio en los ciclos sin cambios, por diseño (ver sección LOGS más abajo).</li>
        <li><b>kick</b> — para cada MAC recién promovida a <code>umacauth.txt</code> en este ciclo que siga conectada (verificado contra <code>stat/sta</code>), fuerza una desasociación vía <code>kick-sta</code> para que el cliente se reconecte de inmediato con su nueva IP fija en vez de competir con su lease de pool ya vencido. También salta cualquier MAC de <code>mac-*.txt</code>, como defensa adicional (estructuralmente inalcanzable aquí, ya que el paso 7 ya las excluye).</li>
      </ol>
      <b>Watcher de cambios en mac-*.txt</b> (independiente, no es un paso numerado): cada ciclo, justo después de <b>snapshot</b>, calcula una huella md5 combinada de todos los <code>mac-*.txt</code> (existencia + contenido, sin parsear MAC/estado) y la compara con la del ciclo anterior. Si cambió, el reload no se dispara de inmediato — queda marcado para que el paso <b>reload</b> lo recoja en el siguiente ciclo, de modo que nunca provoca una segunda invocación separada de <code>ureload.sh</code> en la misma corrida que otra ya disparada por los archivos ACL de arriba.
      <br><br>
      Por eso una edición siempre produce <b>dos</b> líneas de log, separadas por un ciclo, no una — marcan dos momentos distintos, no una duplicación:
      <code>2026-07-23 22:01:28 INFO: mac-*.txt changed -- reload scheduled for next cycle</code><br>
      <code>2026-07-23 22:01:31 INFO: mac-*.txt change from previous cycle -- reloading now</code><br>
      <code>2026-07-23 22:01:31 INFO: invoking /etc/uhotspot/core/ureload.sh</code>
      <br><br>
      La primera línea es el watcher notando el cambio (este ciclo); la segunda es el paso de reload actuando sobre él (ciclo siguiente), seguida de inmediato por la invocación real. Ver solo la primera sin una segunda línea de seguimiento un ciclo después sería en sí misma una señal de que algo anda mal.
    </td>
  </tr>
</table>

### Client Flow

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Client flow</b>: a new client connecting to the SSID receives a pool DHCP lease from <code>pydhcpd</code>. On the daemon's <i>new leases</i> step (every <code>POLL_INTERVAL</code> cycle, not waiting for a separate trigger), <code>uhotspotd</code> scans <code>pydhcpd.leases</code> directly and writes the MAC into <code>ugrace.txt</code> with a timestamp — writing that file is what triggers the reload, which then runs <code>uleases.sh</code> to do the actual classification/expiry/blocking. If the client enters a voucher, <code>uhotspotd</code> promotes it to <code>umacauth.txt</code> and assigns a fixed hotspot-range IP. Regardless of subsequent reconnections, once <code>BLOCKDHCP_GRACE_SECONDS</code> elapses without a voucher the MAC is permanently moved to <code>blockdhcp.txt</code>. When a voucher expires, the MAC is released from <code>umacauth.txt</code> and preserved in <code>umacbak.txt</code>; on reconnect <code>uleases.sh</code> recognizes it and keeps the pool lease without starting a new grace timer. The only way out of <code>blockdhcp.txt</code> is manual removal or addition to <code>mac-*</code>.
      <br><br>
      <b>The <code>umacbak.txt</code> limbo state</b>: once a MAC is added to <code>umacbak.txt</code> (first voucher authorization), it is never removed automatically — there is no code path that does so. A client whose voucher expired and isn't renewed stays in a permanent state that is neither blocked nor authorized: not in <code>umacauth.txt</code> (no Internet from the firewall), not in <code>ugrace.txt</code> (no grace timer, since <code>read_leases</code> skips MACs already in <code>umacbak.txt</code>), and protected from <code>blockdhcp.txt</code> by the backup step. The client only sees UniFi's native captive portal (enforced at the AP level, independent of these Linux ACLs) and can renew with a new voucher at any time. The only way out of this limbo without a new voucher is removing the MAC (or clearing the whole file) from <code>umacbak.txt</code> manually — there is no automatic expiry for this list.
      <br><br>
      <b>Record format</b>: <code>a;MAC;IP;HOSTNAME;END_TIME_EPOCH;</code> in <code>umacauth.txt</code>. <code>a;MAC;IP;HOSTNAME;FIRST_SEEN_EPOCH;</code> in <code>ugrace.txt</code>. <code>umacbak.txt</code> stores only MAC addresses (one per line) — it is a cumulative whitelist, not an ACL.
      <br><br>
      <b>Malformed <code>ugrace.txt</code> lines</b>: <code>uleases.sh</code>'s <code>expire_grace_entries()</code> discards, rather than keeps, any line with a bad status/MAC/epoch field. This is intentional: the only writer of this file always writes a valid entry, so a dropped MAC is simply re-added correctly on its next DHCP lease renewal — keeping a malformed line instead would block that self-repair, since the file's own MAC-match check would treat it as already tracked and never write a fresh, valid entry for it.
      <br><br>
      <b>Auth resilience</b>: the CSRF token is extracted from the UniFi OS JWT payload (<code>csrfToken</code> field, <code>unifi-os</code>) or from the response header (<code>classic</code>) after login, and persisted to <code>/run/uhotspotd_session</code> so it survives across <code>$(...)</code> subshell boundaries. On HTTP 401 from any API call, the daemon re-authenticates once and retries automatically.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Flujo del cliente</b>: un cliente nuevo que se conecta al SSID recibe un lease DHCP de pool de <code>pydhcpd</code>. En el paso de <i>clientes nuevos</i> del daemon (cada ciclo de <code>POLL_INTERVAL</code>, sin esperar un disparador aparte), <code>uhotspotd</code> escanea <code>pydhcpd.leases</code> directamente y escribe la MAC en <code>ugrace.txt</code> con un timestamp — escribir ese archivo es lo que dispara el reload, que a su vez ejecuta <code>uleases.sh</code> para hacer la clasificación/expiración/bloqueo real. Si el cliente introduce un voucher, <code>uhotspotd</code> lo promueve a <code>umacauth.txt</code> y le asigna una IP fija del rango hotspot. Sin importar las reconexiones posteriores, una vez transcurrido <code>BLOCKDHCP_GRACE_SECONDS</code> sin voucher el MAC pasa permanentemente a <code>blockdhcp.txt</code>. Cuando un voucher expira, la MAC se libera de <code>umacauth.txt</code> y se preserva en <code>umacbak.txt</code>; al reconectarse, <code>uleases.sh</code> la reconoce y mantiene el lease de pool sin iniciar un nuevo contador de gracia. La única salida de <code>blockdhcp.txt</code> es la eliminación manual o su incorporación a <code>mac-*</code>.
      <br><br>
      <b>El estado "limbo" de <code>umacbak.txt</code></b>: una vez que una MAC entra a <code>umacbak.txt</code> (primera autorización con voucher), nunca se remueve automáticamente — no existe ninguna ruta de código que lo haga. Un cliente cuyo voucher expiró y no lo renueva queda en un estado permanente que no es ni bloqueado ni autorizado: no está en <code>umacauth.txt</code> (sin Internet vía firewall), no está en <code>ugrace.txt</code> (sin contador de gracia, porque <code>read_leases</code> salta las MACs que ya están en <code>umacbak.txt</code>), y está protegido de <code>blockdhcp.txt</code> por el paso backup. El cliente solo ve el portal cautivo nativo de UniFi (aplicado a nivel del AP, independiente de estas ACLs de Linux) y puede renovar con un voucher nuevo en cualquier momento. La única salida de este limbo sin un voucher nuevo es eliminar la MAC (o vaciar el archivo completo) de <code>umacbak.txt</code> manualmente — no hay expiración automática para esta lista.
      <br><br>
      <b>Formato de registro</b>: <code>a;MAC;IP;HOSTNAME;END_TIME_EPOCH;</code> en <code>umacauth.txt</code>. <code>a;MAC;IP;HOSTNAME;FIRST_SEEN_EPOCH;</code> en <code>ugrace.txt</code>. <code>umacbak.txt</code> guarda solo MACs (uno por línea) — es una whitelist acumulativa, no una ACL.
      <br><br>
      <b>Líneas malformadas en <code>ugrace.txt</code></b>: <code>expire_grace_entries()</code> de <code>uleases.sh</code> descarta, en vez de conservar, cualquier línea con status/MAC/epoch inválido. Es intencional: el único proceso que escribe este archivo siempre escribe una entrada válida, así que una MAC descartada simplemente se vuelve a agregar correctamente en su siguiente renovación de lease DHCP — conservar la línea malformada en cambio bloquearía esa autoreparación, porque el chequeo de coincidencia por MAC del archivo la trataría como ya rastreada y nunca escribiría una entrada nueva y válida para ella.
      <br><br>
      <b>Resiliencia de auth</b>: el token CSRF se extrae del payload JWT de UniFi OS (campo <code>csrfToken</code>, <code>unifi-os</code>) o del header de respuesta (<code>classic</code>) tras el login, y se persiste en <code>/run/uhotspotd_session</code> para que sobreviva el límite de subshells <code>$(...)</code>. Ante HTTP 401 de cualquier llamada API, el daemon re-autentica una vez y reintenta automáticamente.
    </td>
  </tr>
</table>

### Firewall Rules (user-provided)

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>uhotspotd</code> does not touch the firewall. The firewall is managed independently by the administrator via <code>/etc/uhotspot/tools/uiptables.sh</code>, which is invoked by <code>ureload.sh</code> after every ACL change. The script flushes and rebuilds all ipsets and iptables rules from scratch on each run. Variables are loaded exclusively from <code>uhotspot.conf</code> — no hardcoded values.
      <br><br>
      The exact ipsets, rule order, and redirects are defined in <a href="tools/uiptables_example.sh"><code>tools/uiptables_example.sh</code></a> — read that file directly rather than a copy here, since it changes independently of this document and a duplicated excerpt would inevitably drift out of sync with the real rules.
      <br><br>
      <b>Note:</b> <code>uiptables.sh</code> is invoked automatically by <code>ureload.sh</code> — never run it manually during normal operation. The script flushes ALL iptables rules and ipsets on every run. Variables (<code>$lan</code>, <code>$wan</code>, <code>$localnet</code>, <code>$netmask</code>, <code>$serverip</code>, <code>$cpd_tcp</code>, <code>$SERV_DNS</code>) are loaded at runtime exclusively from <code>uhotspot.conf</code>.
      <br><br>
      <b>Unconfigured stub:</b> <code>usetup.sh</code> deploys <code>uiptables.sh</code> as a stub that exits 1 with a "not configured" message — this is the normal state right after install, before the admin adapts <code>uiptables_example.sh</code> into it. <code>ureload.sh</code> detects this (missing file, or a file still containing the stub's marker text) and skips it with a log warning/info line instead of treating it as a reload failure — ACL classification (grace/authorized/blocked) keeps working normally, only firewall enforcement is on hold until the script is configured. See <a href="#ureload"><code>ureload</code></a> in the CORE section for exactly how failures of this script (and of <code>uleases.sh</code>) are handled.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>uhotspotd</code> no toca el firewall. El firewall es gestionado independientemente por el administrador vía <code>/etc/uhotspot/tools/uiptables.sh</code>, invocado por <code>ureload.sh</code> tras cada cambio de ACL. El script vacía y reconstruye todos los ipsets y reglas iptables desde cero en cada ejecución. Las variables se cargan exclusivamente desde <code>uhotspot.conf</code> — sin valores hardcodeados.
      <br><br>
      Los ipsets exactos, el orden de reglas y las redirecciones están definidos en <a href="tools/uiptables_example.sh"><code>tools/uiptables_example.sh</code></a> — consulte ese archivo directamente en vez de una copia aquí, ya que cambia independientemente de este documento y un extracto duplicado inevitablemente quedaría desincronizado de las reglas reales.
      <br><br>
      <b>Nota:</b> <code>uiptables.sh</code> es invocado automáticamente por <code>ureload.sh</code> — nunca ejecutarlo manualmente durante operación normal. El script vacía TODAS las reglas iptables e ipsets en cada ejecución. Las variables (<code>$lan</code>, <code>$wan</code>, <code>$localnet</code>, <code>$netmask</code>, <code>$serverip</code>, <code>$cpd_tcp</code>, <code>$SERV_DNS</code>) se cargan en tiempo de ejecución exclusivamente desde <code>uhotspot.conf</code>.
      <br><br>
      <b>Stub sin configurar:</b> <code>usetup.sh</code> despliega <code>uiptables.sh</code> como un stub que sale con código 1 y un mensaje "not configured" — es el estado normal justo tras instalar, antes de que el admin adapte <code>uiptables_example.sh</code> dentro de él. <code>ureload.sh</code> detecta esto (archivo ausente, o presente pero con el texto marcador del stub) y lo salta con una línea de warning/info en el log en vez de tratarlo como un fallo de reload — la clasificación de ACLs (gracia/autorizado/bloqueado) sigue funcionando normal, solo la aplicación del firewall queda en pausa hasta que se configure el script. Ver <a href="#ureload"><code>ureload</code></a> en la sección CORE para el detalle exacto de cómo se maneja el fallo de este script (y el de <code>uleases.sh</code>).
    </td>
  </tr>
</table>

**Required UniFi ports (hardcoded in `uiptables.sh`):**

| Port | Proto | Direction | Purpose | Propósito |
|---|---|---|---|---|
| 8080 | TCP | LAN → controller | AP-to-controller communication | Comunicación AP-controlador |
| 8880 | TCP | LAN → controller | Captive portal HTTP | Portal cautivo HTTP |
| 8881 | TCP | LAN → controller | Captive portal HTTP alternate | Portal cautivo HTTP alternativo |
| 8882 | TCP | LAN → controller | Captive portal HTTP alternate | Portal cautivo HTTP alternativo |
| 8843 | TCP | LAN → controller | Captive portal HTTPS | Portal cautivo HTTPS |
| 6789 | TCP | LAN → controller | UniFi speed test / throughput measurement | Prueba de velocidad UniFi / medición de throughput |
| 10001 | UDP | LAN ↔ APs | Device discovery | Descubrimiento de dispositivos |
| 3478 | UDP | LAN → WAN | STUN for APs behind NAT | STUN para APs detrás de NAT |
| 123 | UDP | LAN → WAN | NTP time sync | Sincronización NTP |

> For the full list of UniFi required ports see: [help.ui.com/hc/en-us/articles/218506997](https://help.ui.com/hc/en-us/articles/218506997-Required-Ports-Reference)
>
> Para la lista completa de puertos requeridos por UniFi, consulte: [help.ui.com/hc/en-us/articles/218506997](https://help.ui.com/hc/en-us/articles/218506997-Required-Ports-Reference)

## CORE

---

> **`core/` holds the reload mechanism itself — uhotspot cannot function without any of these.** `uhotspotd.sh`/`uhotspotd.service` run the daemon, `ureload.sh` is the wrapper it invokes on every ACL change, and `uleases.sh` is the actual ACL/lease reconciliation `ureload.sh` calls. `tools/` (next section) holds independent, optional utilities uhotspot runs fine without. `uiptables.sh` is the one exception living under `tools/`: required for firewall enforcement, but its absence does not stop `uhotspotd` from starting or from classifying clients correctly — see [`ureload`](#ureload) below for exactly how failures of each script are handled.
>
> **`core/` contiene el mecanismo de reload en sí — uhotspot no puede funcionar sin ninguno de estos.** `uhotspotd.sh`/`uhotspotd.service` ejecutan el daemon, `ureload.sh` es el wrapper que este invoca en cada cambio de ACL, y `uleases.sh` es la reconciliación real de ACLs/leases que `ureload.sh` llama. `tools/` (siguiente sección) contiene utilidades independientes y opcionales sin las cuales uhotspot funciona igual. `uiptables.sh` es la única excepción que vive bajo `tools/`: necesario para la aplicación del firewall, pero su ausencia no impide que `uhotspotd` arranque o clasifique clientes correctamente — ver [`ureload`](#ureload) abajo para el detalle exacto de cómo se maneja el fallo de cada script.

### uhotspotd

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>uhotspotd.sh</code> is the persistent systemd daemon — the entry point of the whole mechanism. It runs a full management cycle every <code>POLL_INTERVAL</code> seconds (default 20), polling the UniFi controller and reconciling ACL files. See <a href="#daemon-cycle">Daemon Cycle</a> above for the full 11-step breakdown.
      <br><br>
      Installed at <code>/etc/uhotspot/core/uhotspotd.sh</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>uhotspotd.sh</code> es el daemon systemd persistente — el punto de entrada de todo el mecanismo. Ejecuta un ciclo de gestión completo cada <code>POLL_INTERVAL</code> segundos (default 20), consultando el controlador UniFi y reconciliando los archivos ACL. Ver <a href="#daemon-cycle">Daemon Cycle</a> arriba para el detalle completo de los 11 pasos.
      <br><br>
      Instalado en <code>/etc/uhotspot/core/uhotspotd.sh</code>.
    </td>
  </tr>
</table>

#### Startup sequence (server or controller reboot)

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Right after a host reboot, the login endpoint typically answers before the UniFi controller's data endpoints (<code>stat/voucher</code>, <code>stat/guest</code>, <code>stat/sta</code>) finish initializing. A login success does <b>not</b> by itself mean the backend is fully usable yet — the log shows both milestones separately:
    </td>
    <td style="width: 50%; vertical-align: top;">
      Justo después de un reinicio del host, el endpoint de login típicamente responde antes de que los endpoints de datos del controlador UniFi (<code>stat/voucher</code>, <code>stat/guest</code>, <code>stat/sta</code>) terminen de inicializar. Que el login tenga éxito <b>no</b> significa por sí solo que el backend ya esté completamente operativo — el log muestra ambos hitos por separado:
    </td>
  </tr>
</table>

```text
2026-07-12 21:41:10 INFO: UniFi login attempt failed (HTTP 000) — still within startup grace window
2026-07-12 21:41:20 INFO: UniFi login attempt failed (HTTP 000) — still within startup grace window
2026-07-12 21:41:30 INFO: UniFi login attempt failed (HTTP 000) — still within startup grace window
2026-07-12 21:41:50 INFO: UniFi login OK
2026-07-12 21:41:51 WARNING: Could not load vouchers (rc=empty)
2026-07-12 21:41:56 INFO: stat/guest unavailable — skipping sessions
2026-07-12 21:41:56 INFO: stat/sta unavailable — skipping revoke
2026-07-12 21:42:11 WARNING: Could not load vouchers (rc=empty)
2026-07-12 21:42:16 INFO: stat/guest unavailable — skipping sessions
2026-07-12 21:42:16 INFO: stat/sta unavailable — skipping revoke
2026-07-12 21:42:31 INFO: UniFi backend ready (voucher/guest/sta OK)
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Both parts are expected and self-resolving. The login retries are <code>uhotspotd.sh</code> waiting out <code>STARTUP_GRACE_SECONDS</code> while UniFi OS itself is still coming up. The couple of data-endpoint failures right after a successful login happen because UniFi OS brings its auth endpoint up slightly before the rest of its API is ready to serve — a few seconds of lag, not a real failure. <code>UniFi backend ready</code> logs exactly once, on the transition from any of <code>stat/voucher</code>/<code>stat/guest</code>/<code>stat/sta</code> failing to all three succeeding together — the single line to watch for "the daemon is now fully operational" instead of inferring it from the absence of further warnings.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Ambas partes son esperadas y se resuelven solas. Los reintentos de login son <code>uhotspotd.sh</code> esperando a que termine <code>STARTUP_GRACE_SECONDS</code> mientras UniFi OS todavía está iniciando. Los fallos en los endpoints de datos justo después de un login exitoso ocurren porque UniFi OS activa su endpoint de autenticación un poco antes de que el resto de su API esté lista para responder — unos segundos de retraso, no un fallo real. <code>UniFi backend ready</code> se registra exactamente una vez, en la transición de cualquiera de <code>stat/voucher</code>/<code>stat/guest</code>/<code>stat/sta</code> fallando a los tres respondiendo juntos — la línea a observar para saber "el daemon ya está completamente operativo" en vez de inferirlo por la ausencia de más advertencias.
    </td>
  </tr>
</table>

#### Managed MAC lists are optional

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>mac-*.txt</code> files are entirely optional. <code>usetup.sh</code> only creates the empty <code>/etc/acl/acl_mac</code> directory; it never creates any <code>mac-*.txt</code> file itself. <code>uleases.sh</code> does create <code>mac-proxy.txt</code> and <code>mac-unlimited.txt</code> (empty) on its first run if they're missing, but an admin who never writes an actual entry into either is running a fully supported configuration: with no managed MACs, every client goes through the normal guest flow (grace → voucher → captive portal), with no exceptions. Nothing in <code>uhotspotd.sh</code> or <code>uleases.sh</code> requires a non-empty <code>mac-*.txt</code> to function — every place that reads them (a glob with <code>nullglob</code>, or a fixed path already guaranteed to exist) degrades cleanly to "nothing is managed" when they're empty or absent.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Los archivos <code>mac-*.txt</code> son totalmente opcionales. <code>usetup.sh</code> solo crea el directorio vacío <code>/etc/acl/acl_mac</code>; nunca crea ningún archivo <code>mac-*.txt</code> por sí mismo. <code>uleases.sh</code> sí crea <code>mac-proxy.txt</code> y <code>mac-unlimited.txt</code> (vacíos) en su primera ejecución si faltan, pero un administrador que nunca escribe una entrada real en ninguno de los dos está corriendo una configuración totalmente soportada: sin MACs gestionadas, todo cliente pasa por el flujo normal de invitados (gracia → voucher → portal cautivo), sin excepciones. Nada en <code>uhotspotd.sh</code> ni <code>uleases.sh</code> requiere que un <code>mac-*.txt</code> tenga contenido para funcionar — cada lugar que los lee (un glob con <code>nullglob</code>, o una ruta fija ya garantizada existente) degrada limpiamente a "nada está gestionado" cuando están vacíos o ausentes.
    </td>
  </tr>
</table>

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Recommendation:</b> infrastructure equipment that gets its DHCP lease from the same <code>pydhcpd</code> instance as the guest network (APs, switches, and similar communications gear on the same subnet) should be listed in <code>mac-unlimited.txt</code>. Without an entry, such a device is indistinguishable from any unknown guest client: it enters <code>ugrace.txt</code> on first lease, and once <code>BLOCKDHCP_GRACE_SECONDS</code> elapses without a voucher — which infrastructure gear has no way to redeem, since it never opens the captive portal itself — <code>uleases.sh</code> moves it to <code>blockdhcp.txt</code>, and <code>pydhcpd</code> denies it any further lease. That is a verified mechanism, not a guess; whether losing DHCP renewal actually degrades that specific device (reboot loop, lost management access, etc.) depends on the device itself and is outside what this project's code can determine — the safe default is simply not to let infrastructure gear go through the same unknown-client path guests do.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Recomendación:</b> el equipo de infraestructura que obtiene su lease DHCP del mismo <code>pydhcpd</code> que la red de invitados (APs, switches y equipos de comunicaciones similares en la misma subred) debería estar listado en <code>mac-unlimited.txt</code>. Sin una entrada, ese dispositivo es indistinguible de cualquier cliente invitado desconocido: entra a <code>ugrace.txt</code> en su primer lease, y una vez que pasa <code>BLOCKDHCP_GRACE_SECONDS</code> sin voucher — que el equipo de infraestructura no tiene forma de canjear, ya que nunca abre el portal cautivo por sí mismo — <code>uleases.sh</code> lo mueve a <code>blockdhcp.txt</code>, y <code>pydhcpd</code> le niega cualquier lease posterior. Ese es un mecanismo verificado, no una suposición; si perder la renovación DHCP realmente degrada a ese dispositivo en particular (bucle de reinicio, pérdida de acceso de gestión, etc.) depende del propio equipo y queda fuera de lo que el código de este proyecto puede determinar — lo seguro por defecto es simplemente no dejar que el equipo de infraestructura pase por el mismo camino de cliente desconocido que los invitados.
    </td>
  </tr>
</table>

#### Managed MAC list edits (mac-*.txt)

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Editing any <code>mac-*.txt</code> file — adding, removing, commenting (<code>#a;…</code>) or uncommenting (<code>a;…</code>) a line, changing an IP/hostname — is detected by the independent watcher described in <a href="#daemon-cycle">Daemon Cycle</a> (a combined md5 of the whole <code>mac-*.txt</code> set, compared across cycles). It never parses which MAC changed or what changed about it — only that the set as a whole differs from the previous cycle. The change is flagged in the cycle it's detected, and the reload itself fires on the <b>next</b> cycle:
    </td>
    <td style="width: 50%; vertical-align: top;">
      Editar cualquier archivo <code>mac-*.txt</code> — agregar, quitar, comentar (<code>#a;…</code>) o descomentar (<code>a;…</code>) una línea, cambiar una IP/hostname — es detectado por el watcher independiente descrito en <a href="#daemon-cycle">Daemon Cycle</a> (un md5 combinado de todo el conjunto <code>mac-*.txt</code>, comparado entre ciclos). Nunca parsea qué MAC cambió ni qué cambió en ella — solo que el conjunto completo difiere del ciclo anterior. El cambio se marca en el ciclo donde se detecta, y el reload en sí se dispara en el ciclo <b>siguiente</b>:
    </td>
  </tr>
</table>

```text
2026-07-23 14:13:45 INFO: mac-*.txt changed -- reload scheduled for next cycle
2026-07-23 14:14:05 INFO: mac-*.txt change from previous cycle -- reloading now
2026-07-23 14:14:05 INFO: invoking /etc/uhotspot/core/ureload.sh
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Whatever the edit actually was (block/reactivate/add/remove/IP change), <code>uleases.sh</code> is what interprets it on that reload: an active (<code>a;</code>) line gets a fixed-address DHCP entry; a commented (<code>#a;</code>) line joins the same <code>blockdhcp</code> deny class as <code>blockdhcp.txt</code>, so <code>pydhcpd</code> denies it a lease outright.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Sea cual sea la edición real (bloqueo/reactivación/alta/baja/cambio de IP), <code>uleases.sh</code> es quien la interpreta en ese reload: una línea activa (<code>a;</code>) recibe una entrada DHCP de dirección fija; una línea comentada (<code>#a;</code>) entra en la misma clase de denegación <code>blockdhcp</code> que <code>blockdhcp.txt</code>, así que <code>pydhcpd</code> le niega el lease directamente.
    </td>
  </tr>
</table>

### uhotspotd.service

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Systemd unit for <code>uhotspotd.sh</code>. <code>Restart=always</code> with <code>RestartSec=10</code> restarts the daemon on any crash; <code>StartLimitIntervalSec=300</code> / <code>StartLimitBurst=10</code> (in <code>[Unit]</code>) cap it at 10 restarts per 5 minutes before systemd marks it <code>start-limit-hit</code> and stops trying — a general crash-loop guard, not specific to any one failure mode. <code>After=network.target pydhcpd.service</code> / <code>Wants=pydhcpd.service</code> order startup after the DHCP backend, though <code>uhotspotd.sh</code> still tolerates <code>pydhcpd</code> coming up late via its own startup grace (see <a href="#daemon-cycle">Daemon Cycle</a>).
      <br><br>
      Installed at <code>/etc/systemd/system/uhotspotd.service</code>, deployed from <code>/etc/uhotspot/core/uhotspotd.service</code>.
      <br><br>
      <b>Note — sandboxing</b>: <code>ProtectHome=read-only</code>, <code>ProtectControlGroups=yes</code>, <code>ProtectClock=yes</code>, <code>ProtectHostname=yes</code>, <code>ProtectKernelLogs=yes</code>, <code>LockPersonality=yes</code>, <code>RestrictRealtime=yes</code> and <code>RestrictSUIDSGID=yes</code> are applied — none of them intersect any path or syscall this daemon or its reload chain actually uses. Two more common hardening directives are intentionally <b>not</b> set, because they would break real functionality: <code>ProtectSystem=strict</code> would make <code>/etc</code> read-only, but <code>uleases.sh</code> rewrites <code>/etc/pydhcp/pydhcpd.conf</code> and <code>pydhcpd.leases</code> on every reload, and the admin-supplied <code>uiptables.sh</code> is arbitrary code that may need to write anywhere on the system (persistent ipset/iptables rule files, etc.) — a static <code>ReadWritePaths</code> allowlist can't be correct in general for a script the admin fully controls. <code>NoNewPrivileges=yes</code> would break <code>uleases.sh</code>'s desktop-notification path (<code>_notify()</code>, which calls <code>sudo -u $user notify-send</code>) — modern <code>sudo</code> explicitly detects the no-new-privileges flag and refuses to run, even when the calling process is already root.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Unit systemd para <code>uhotspotd.sh</code>. <code>Restart=always</code> con <code>RestartSec=10</code> reinicia el daemon ante cualquier caída; <code>StartLimitIntervalSec=300</code> / <code>StartLimitBurst=10</code> (en <code>[Unit]</code>) lo limitan a 10 reinicios cada 5 minutos antes de que systemd lo marque <code>start-limit-hit</code> y deje de intentarlo — una protección general contra crash-loops, no específica de un solo modo de fallo. <code>After=network.target pydhcpd.service</code> / <code>Wants=pydhcpd.service</code> ordenan el arranque después del backend DHCP, aunque <code>uhotspotd.sh</code> igual tolera que <code>pydhcpd</code> arranque tarde gracias a su propio período de gracia al inicio (ver <a href="#daemon-cycle">Daemon Cycle</a>).
      <br><br>
      Instalado en <code>/etc/systemd/system/uhotspotd.service</code>, desplegado desde <code>/etc/uhotspot/core/uhotspotd.service</code>.
      <br><br>
      <b>Nota — sandboxing</b>: se aplican <code>ProtectHome=read-only</code>, <code>ProtectControlGroups=yes</code>, <code>ProtectClock=yes</code>, <code>ProtectHostname=yes</code>, <code>ProtectKernelLogs=yes</code>, <code>LockPersonality=yes</code>, <code>RestrictRealtime=yes</code> y <code>RestrictSUIDSGID=yes</code> — ninguna interseca con ninguna ruta o syscall que el daemon o su cadena de reload usen realmente. Dos directivas de hardening comunes se dejan intencionalmente <b>fuera</b>, porque romperían funcionalidad real: <code>ProtectSystem=strict</code> dejaría <code>/etc</code> de solo lectura, pero <code>uleases.sh</code> reescribe <code>/etc/pydhcp/pydhcpd.conf</code> y <code>pydhcpd.leases</code> en cada reload, y el <code>uiptables.sh</code> que provee el administrador es código arbitrario que puede necesitar escribir en cualquier parte del sistema (archivos de persistencia de ipset/iptables, etc.) — una whitelist estática de <code>ReadWritePaths</code> no puede ser correcta en general para un script que el administrador controla por completo. <code>NoNewPrivileges=yes</code> rompería la ruta de notificaciones de escritorio de <code>uleases.sh</code> (<code>_notify()</code>, que llama <code>sudo -u $user notify-send</code>) — el <code>sudo</code> moderno detecta explícitamente la bandera de no-nuevos-privilegios y se niega a ejecutar, incluso cuando el proceso que llama ya es root.
    </td>
  </tr>
</table>

### ureload

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>ureload.sh</code> is the reload wrapper — invoked by <code>uhotspotd</code> after every ACL change, or on its own safety-net cadence (<code>RELOAD_SAFETY_INTERVAL_SECONDS</code>, default 1h) even without a diff, so idle networks still get grace→block promotion and firewall self-healing. It can also be run manually for troubleshooting. It runs <code>uleases.sh</code> (lease/ACL rebuild) and then <code>uiptables.sh</code> (firewall rules), in that order — but the two are <b>not</b> treated the same on failure (see table below).
      <br><br>
      This asymmetry reflects what each script actually is: <code>uleases.sh</code> is the core ACL/lease reconciliation step — nothing downstream can be trusted without it. <code>uiptables.sh</code> only enforces at the firewall level, and ships as a stub that intentionally exits 1 until the admin configures it (see <a href="#firewall-rules-user-provided">Firewall Rules</a>) — that stub state is detected and skipped the same way as a missing file, so a fresh install does not generate a warning/trace file on every reload cycle. Only its absence (stub or otherwise) is tolerated; a genuine execution failure of a configured <code>uiptables.sh</code> still aborts.
      <br><br>
      Installed at <code>/etc/uhotspot/core/ureload.sh</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>ureload.sh</code> es el wrapper de reload — invocado por <code>uhotspotd</code> tras cada cambio de ACL, o en su propia cadencia de respaldo (<code>RELOAD_SAFETY_INTERVAL_SECONDS</code>, default 1h) incluso sin diff, para que las redes inactivas sigan teniendo la promoción gracia→bloqueo y la auto-reparación del firewall. También puede ejecutarse manualmente para diagnóstico. Ejecuta <code>uleases.sh</code> (reconstrucción de leases/ACL) y luego <code>uiptables.sh</code> (reglas de firewall), en ese orden — pero los dos <b>no</b> reciben el mismo trato ante un fallo (ver tabla abajo).
      <br><br>
      Esta asimetría refleja lo que cada script realmente es: <code>uleases.sh</code> es el paso central de reconciliación de ACLs/leases — nada aguas abajo es confiable sin él. <code>uiptables.sh</code> solo aplica a nivel de firewall, y se despliega como un stub que sale con código 1 intencionalmente hasta que el admin lo configura (ver <a href="#firewall-rules-user-provided">Firewall Rules</a>) — ese estado de stub se detecta y se salta igual que un archivo ausente, así una instalación recién hecha no genera una advertencia/trace en cada ciclo de reload. Solo su ausencia (stub o no) se tolera; un fallo real de ejecución de un <code>uiptables.sh</code> ya configurado sigue abortando.
      <br><br>
      Instalado en <code>/etc/uhotspot/core/ureload.sh</code>.
    </td>
  </tr>
</table>

> **Failure handling:** `uleases.sh` — missing/not executable or exists but fails: abort reload (`WARNING` + exit 1) either way. `uiptables.sh` — missing/not executable: warn and continue, reload still counts as done; exists but fails: abort reload (`WARNING` + exit 1).
>
> **Manejo de fallos:** `uleases.sh` — falta/no ejecutable o existe pero falla: aborta el reload (`WARNING` + exit 1) en ambos casos. `uiptables.sh` — falta/no ejecutable: avisa y continúa, el reload igual cuenta como hecho; existe pero falla: aborta el reload (`WARNING` + exit 1).

### uleases

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>uleases.sh</b> is a <b>reimplementation</b> of the <code>pyleases.sh</code> shipped by default with <a href="https://github.com/maravento/pydhcp">pydhcp</a>, with built-in UniFi Hotspot integration. The original version manages DHCP leases and ACLs but has no awareness of the UniFi captive portal. This version adds the <i>UniFi Hotspot Integration</i> module: when <code>UNIFI_HOTSPOT_ENABLED=true</code>, uleases reads <code>/etc/uhotspot/acl/umacauth.txt</code> and <code>/etc/uhotspot/acl/ugrace.txt</code> as authoritative classification lists during lease processing, applies a grace period for unseen MACs (<code>BLOCKDHCP_GRACE_SECONDS</code>, default 24h), and synchronizes hotspot-related ACL entries.
      <br><br>
      The script runs from <code>/etc/uhotspot/core/uleases.sh</code> and detects the existence of <code>/etc/pydhcp</code> (required). Configuration is read exclusively from <code>/etc/uhotspot/uhotspot.conf</code> (generated and managed by <code>usetup.sh</code>). To reconfigure, edit <code>uhotspot.conf</code> directly or re-run <code>usetup.sh</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>uleases.sh</b> es una <b>reimplementación</b> del <code>pyleases.sh</code> que viene por defecto con <a href="https://github.com/maravento/pydhcp">pydhcp</a>, con integración UniFi Hotspot incorporada. La versión original gestiona leases DHCP y ACLs pero no sabe nada del portal cautivo de UniFi. Esta versión añade el módulo <i>UniFi Hotspot Integration</i>: cuando <code>UNIFI_HOTSPOT_ENABLED=true</code>, uleases lee <code>/etc/uhotspot/acl/umacauth.txt</code> y <code>/etc/uhotspot/acl/ugrace.txt</code> como listas autoritativas de clasificación durante el procesamiento de leases, aplica un período de gracia para MACs nuevas (<code>BLOCKDHCP_GRACE_SECONDS</code>, default 24h), y sincroniza entradas ACL relacionadas con el hotspot.
      <br><br>
      El script se ejecuta desde <code>/etc/uhotspot/core/uleases.sh</code> y detecta la existencia de <code>/etc/pydhcp</code> (requerido). La configuración se lee exclusivamente desde <code>/etc/uhotspot/uhotspot.conf</code> (generado y gestionado por <code>usetup.sh</code>). Para reconfigurar, edite <code>uhotspot.conf</code> directamente o vuelva a correr <code>usetup.sh</code>.
    </td>
  </tr>
</table>

**ACL sources consumed by uleases:**

| Path | Role | Rol |
|---|---|---|
| `/etc/acl/acl_mac/mac-proxy.txt` | Authorized — forced through Squid | Autorizados — forzados por Squid |
| `/etc/acl/acl_mac/mac-unlimited.txt` | Authorized — bypass restrictions | Autorizados — sin restricciones |
| `/etc/acl/acl_dhcp/blockdhcp.txt` | Blocked clients | Clientes bloqueados |
| `/etc/uhotspot/acl/ugrace.txt` | Grace-period clients (hotspot mode only) | Período de gracia (solo modo hotspot) |
| `/etc/uhotspot/acl/umacauth.txt` | Hotspot — voucher active (read-only) | Hotspot — voucher activo (solo lectura) |

**Entry format:**

```text
Standard      : a;MAC;IP;HOSTNAME;
Hotspot       : a;MAC;IP;HOSTNAME;END_TIME_EPOCH;
Grace         : a;MAC;IP;HOSTNAME;FIRST_SEEN_EPOCH;
```

> **Why uleases.sh stops/starts pydhcpd instead of reloading it:** Stopping guarantees exclusive access to the leases file while it's rewritten, avoiding a race with a lease the daemon might be persisting at that instant. The brief DHCP downtime on every ACL change is an accepted tradeoff for write safety.
>
> **Por qué uleases.sh detiene/arranca pydhcpd en vez de recargarlo:** Detenerlo garantiza acceso exclusivo al archivo de leases mientras se reescribe, evitando una carrera con un lease que el daemon pudiera estar persistiendo en ese instante. El breve corte de DHCP en cada cambio de ACL es un costo aceptado a cambio de seguridad en la escritura.

**Install (already covered in the Install section above):**

```bash
# uleases.sh is deployed automatically by usetup.sh to /etc/uhotspot/core/
# Configuration is read from /etc/uhotspot/uhotspot.conf (managed by usetup.sh)
# No manual setup required — run usetup.sh to configure everything
```

**Configuration variables (in `uhotspot.conf`):**

| Variable | Default | Description | Descripción |
|----------|---------|-------------|-------------|
| `SERV_DHCP` | *(required)* | DHCP server IP address | Dirección IP del servidor DHCP |
| `SERV_SUBNET` | *(auto)* | Network subnet (auto-calculated) | Subred de red (calculada automáticamente) |
| `SERV_BROADCAST` | *(auto)* | Broadcast address (auto-calculated) | Dirección de broadcast (calculada automáticamente) |
| `SERV_MASK` | 255.255.255.0 | Netmask | Máscara de red |
| `SERV_INI_RANGE_BLOCK` | *(required)* | Start of block pool IP range | Inicio del rango de IP del pool de bloqueo |
| `SERV_END_RANGE_BLOCK` | *(required)* | End of block pool IP range | Fin del rango de IP del pool de bloqueo |
| `SERV_DNS` | *(required)* | DNS servers (comma-separated) | Servidores DNS (separados por coma) |
| `ACL_PATH` | /etc/acl | Base path for ACL directories | Ruta base para los directorios ACL |
| `ACL_MAC_PATH` | /etc/acl/acl_mac | MAC-based ACL directory | Directorio ACL basado en MAC |
| `ACL_DHCP_PATH` | /etc/acl/acl_dhcp | DHCP ACL directory | Directorio ACL de DHCP |
| `HOTSPOT_PATH` | /etc/uhotspot | Hotspot working directory | Directorio de trabajo del hotspot |
| `ACL_MAC_PROXY` | /etc/acl/acl_mac/mac-proxy.txt | Proxy-forced clients | Clientes forzados por proxy |
| `ACL_MAC_UNLIMITED` | /etc/acl/acl_mac/mac-unlimited.txt | Unrestricted clients | Clientes sin restricciones |
| `ACL_MAC_HOTSPOT` | /etc/uhotspot/acl/umacauth.txt | Hotspot authorized (read-only) | Autorizados del hotspot (solo lectura) |
| `ACL_BLOCK_FILE` | /etc/acl/acl_dhcp/blockdhcp.txt | Blocked clients | Clientes bloqueados |
| `ACL_GRACE_FILE` | /etc/uhotspot/acl/ugrace.txt | Grace period clients | Clientes en período de gracia |
| `BLOCKDHCP_GRACE_SECONDS` | 86400 | Grace period duration (seconds, 24h) | Duración del período de gracia (segundos, 24h) |
| `UNIFI_HOTSPOT_ENABLED` | true | Enable/disable UniFi Hotspot integration | Habilitar/deshabilitar la integración UniFi Hotspot |
| `CLEANUP_INTERVAL` | 60 | Cleanup frequency and pool lease time (seconds) | Frecuencia de limpieza y tiempo de lease del pool (segundos) |
| `AUTHORIZED_LEASE_TIME` | 2592000 | Lease duration for authorized clients (30 days) | Duración del lease para clientes autorizados (30 días) |
| `WPAD_ENABLED` | false | Enable WPAD/PAC via DHCP option 252 | Habilitar WPAD/PAC vía la opción DHCP 252 |
| `PING_CHECK_ENABLED` | true | Ping IP before OFFER to detect conflicts. Set to `false` in environments with strict ICMP firewall rules | Hacer ping a la IP antes del OFFER para detectar conflictos. Configurar en `false` en entornos con reglas de firewall ICMP estrictas |

> Variables marked as (auto) are calculated automatically from `SERV_DHCP` and `SERV_MASK`. Variables marked as (required) are prompted during `usetup.sh` installation. All other variables have sensible defaults and can be modified directly in `uhotspot.conf`.
>
> Las variables marcadas como (auto) se calculan automáticamente desde `SERV_DHCP` y `SERV_MASK`. Las marcadas como (required) se solicitan durante la instalación con `usetup.sh`. El resto tienen valores predeterminados sensatos y pueden modificarse directamente en `uhotspot.conf`.

##### Supported directives

| Directive | Description | Descripción |
|-----------|-------------|-------------|
| `authoritative;` | Server sends NAK to clients with foreign leases | El servidor envía NAK a clientes con leases ajenos |
| `cleanup-interval N;` | How often (seconds) expired leases are removed from memory (controlled via `CLEANUP_INTERVAL` in `uhotspot.conf`) | Frecuencia (segundos) con que se eliminan leases expirados de memoria (controlado via `CLEANUP_INTERVAL` en `uhotspot.conf`) |
| `server-identifier IP;` | IP the server uses to identify itself in DHCP replies | IP con la que el servidor se identifica en las respuestas DHCP |
| `deny duplicates;` | Reject requests from a MAC that already holds a lease | Rechaza solicitudes de una MAC que ya tiene un lease |
| `one-lease-per-client true;` | Release old lease before assigning a new one to the same MAC | Libera el lease anterior antes de asignar uno nuevo a la misma MAC |
| `deny declines;` | Ignore DHCPDECLINE messages | Ignora mensajes DHCPDECLINE |
| `ping-check true\|false;` | Ping IP before OFFER to detect conflicts (controlled via `PING_CHECK_ENABLED` in `uhotspot.conf`) | Ping a la IP antes del OFFER para detectar conflictos (controlado via `PING_CHECK_ENABLED` en `uhotspot.conf`) |
| `option wpad ...;` | WPAD/PAC proxy auto-configuration (controlled via `WPAD_ENABLED` in `uhotspot.conf`) | Autoconfiguración de proxy WPAD/PAC (controlado via `WPAD_ENABLED` en `uhotspot.conf`) |
| `subnet ... { pool { ... } }` | Subnet declaration with dynamic block pool | Declaración de subred con pool de bloqueo dinámico |
| `host NAME { hardware ethernet MAC; fixed-address IP; }` | Static host reservation from ACL files | Reserva estática de host desde archivos ACL |
| `class "blockdhcp" { ... }` / `subclass "blockdhcp" ...` | MAC-based DHCP block list | Lista de bloqueo DHCP por MAC |
| `min-lease-time`, `default-lease-time`, `max-lease-time` | Lease duration controls | Control de duración de leases |
| `option routers`, `option broadcast-address`, `option domain-name-servers` | Standard DHCP options | Opciones DHCP estándar |

##### Warning

|  |  |
|---|---|
| `uleases.sh` fully rebuilds `/etc/pydhcp/pydhcpd.conf` on every run from its ACL files and `uhotspot.conf`. Any manual edits to `pydhcpd.conf` — including custom lease times, pools, or directives — will be lost. If you manage `pydhcpd.conf` manually, do not use `uleases.sh`. | `uleases.sh` reconstruye completamente `/etc/pydhcp/pydhcpd.conf` en cada ejecución a partir de sus archivos ACL y `uhotspot.conf`. Cualquier edición manual a `pydhcpd.conf` — incluyendo lease times, pools o directivas personalizadas — se perderá. Si gestiona `pydhcpd.conf` manualmente, no utilice `uleases.sh`. |
| **Deactivating a managed MAC**: commenting out a line in a `mac-*.txt` file (prefixing it with `#`) keeps it in place, IP included, but gives it the exact same treatment as a `blockdhcp.txt` entry — `uleases.sh` adds it to the `"blockdhcp"` DHCP class in `pydhcpd.conf`, so `pydhcpd` denies it a lease outright. It never physically enters `blockdhcp.txt`. | **Desactivar una MAC gestionada**: comentar una línea en un archivo `mac-*.txt` (agregando `#` al inicio) la deja en su lugar, con su IP incluida, pero recibe exactamente el mismo tratamiento que una entrada de `blockdhcp.txt` — `uleases.sh` la agrega a la clase DHCP `"blockdhcp"` en `pydhcpd.conf`, así que `pydhcpd` le niega la lease directamente. Nunca entra físicamente a `blockdhcp.txt`. |

##### ACL consistency check (`check_acl_conflicts`)

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Before touching anything, <code>uleases.sh</code> runs <code>check_acl_conflicts()</code> against every ACL source (<code>mac-*.txt</code> and, if hotspot mode is enabled, <code>umacauth.txt</code>). It catches two unrelated but equally fatal problems, each reported with its own precise <code>ERROR:</code> line, before aborting with <code>exit 1</code> and a desktop notification (via <code>notify-send</code>):
      <br><br>
      <b>1. Duplicate MAC, IP, or hostname</b> across those sources (e.g. the same device listed in two different <code>mac-*.txt</code> files, or a leftover entry colliding with a live guest).
      <br><br>
      <b>2. A <code>mac-*.txt</code> IP falling inside a range reserved for something else.</b> <code>uhotspot.conf</code> only defines two IP ranges — <code>HOTSPOT_RANGE_START</code>/<code>HOTSPOT_RANGE_END</code> (for <code>umacauth.txt</code>) and <code>SERV_INI_RANGE_BLOCK</code>/<code>SERV_END_RANGE_BLOCK</code> (the pydhcp pool used by <code>ugrace.txt</code>/<code>blockdhcp.txt</code>). <code>mac-*.txt</code> files are administrator-created and administrator-addressed — nothing in <code>uhotspot.conf</code> reserves a range for them, so an IP picked by hand can land inside either of the other two ranges. This is always a misconfiguration, whether or not a guest currently holds that exact IP.
      <br><br>
      If neither problem is found, it proceeds straight into <code>is_pydhcp()</code> (the stop→modify→start pydhcpd cycle) as usual.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Antes de tocar nada, <code>uleases.sh</code> corre <code>check_acl_conflicts()</code> contra cada fuente ACL (<code>mac-*.txt</code> y, si el modo hotspot está habilitado, <code>umacauth.txt</code>). Detecta dos problemas distintos pero igualmente fatales, cada uno con su propia línea <code>ERROR:</code> puntual, antes de abortar con <code>exit 1</code> y una notificación de escritorio (vía <code>notify-send</code>):
      <br><br>
      <b>1. MAC, IP u hostname duplicado</b> entre esas fuentes (ej. el mismo equipo listado en dos archivos <code>mac-*.txt</code> distintos, o una entrada residual que choca con un guest activo).
      <br><br>
      <b>2. Una IP de <code>mac-*.txt</code> que cae dentro de un rango reservado para otra cosa.</b> <code>uhotspot.conf</code> solo define dos rangos de IP — <code>HOTSPOT_RANGE_START</code>/<code>HOTSPOT_RANGE_END</code> (para <code>umacauth.txt</code>) y <code>SERV_INI_RANGE_BLOCK</code>/<code>SERV_END_RANGE_BLOCK</code> (el pool de pydhcp usado por <code>ugrace.txt</code>/<code>blockdhcp.txt</code>). Los archivos <code>mac-*.txt</code> son creados y direccionados por el administrador — nada en <code>uhotspot.conf</code> les reserva un rango, así que una IP elegida a mano puede caer dentro de cualquiera de los otros dos rangos. Esto siempre es un error de configuración, sin importar si en ese momento un guest tiene o no esa IP exacta.
      <br><br>
      Si no se encuentra ninguno de los dos problemas, continúa directo a <code>is_pydhcp()</code> (el ciclo detener→modificar→arrancar de pydhcpd) normalmente.
    </td>
  </tr>
</table>

```text
2026-07-18 20:32:50 ERROR: duplicate IP '192.168.10.198' in: /etc/acl/acl_mac/mac-unlimited.txt /etc/uhotspot/acl/umacauth.txt
2026-07-18 20:32:50 ACL configuration error detected — aborting
```

```text
2026-07-18 20:32:50 ERROR: mac-*.txt IP conflict: aa:bb:cc:dd:ee:01 uses 192.168.10.198, inside the hotspot range 192.168.10.180-220 reserved for umacauth.txt — move it outside that range
2026-07-18 20:32:50 ACL configuration error detected — aborting
```

```text
2026-07-18 20:32:50 ERROR: mac-*.txt IP conflict: aa:bb:cc:dd:ee:02 uses 192.168.10.235, inside the blockdhcp pool range 192.168.10.230-192.168.10.239 reserved for ugrace/blockdhcp — move it outside that range
2026-07-18 20:32:50 ACL configuration error detected — aborting
```

Desktop notification sent for any of the three cases above / Notificación de escritorio enviada para cualquiera de los tres casos anteriores:

| Title / Título | Body / Cuerpo |
|---|---|
| `Warning: Abort` | `ACL configuration error. Check /var/log/uhotspot.log` |

## TOOLS

---

> **Independent, optional utilities — uhotspot runs fine without any of these.** See [CORE](#core) above for the reload mechanism itself.
>
> **Utilidades independientes y opcionales — uhotspot funciona igual sin ninguna de estas.** Ver [CORE](#core) arriba para el mecanismo de reload en sí.

### uaudit

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>uaudit.sh</b> — Authenticates against UniFi OS ( <code>/api/auth/login</code>) by default, or classic controllers ( <code>/api/login</code>) when <code>UNIFI_TYPE=classic</code>, and pulls three datasets: <code>stat/sta</code> (live clients), <code>stat/guest</code> (voucher-redeemed guests), and <code>stat/voucher</code> (full voucher inventory). Cross-references them against <code>umacauth.txt</code>, then prints a two-section report (Authorized, Vouchers) and offers five interactive cleanup actions. <br>
      <br>
      Logs to <code>/var/log/uaudit.log</code>. <br>
      <br> Reads credentials from <code>/etc/uhotspot/uhotspot.conf</code>. Required variables: <code>UNIFI_CONTROLLER_URL</code>, <code>UNIFI_USERNAME</code>, <code>UNIFI_PASSWORD</code>, <code>HOTSPOT_ESSID</code>. Optional: <code>UNIFI_SITE</code> (defaults to <code>default</code>).
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>uaudit.sh</b> — Se autentica contra UniFi OS ( <code>/api/auth/login</code>) por defecto, o contra controladores classic ( <code>/api/login</code>) cuando <code>UNIFI_TYPE=classic</code>, y consulta tres datasets: <code>stat/sta</code> (clientes en vivo), <code>stat/guest</code> (invitados con voucher canjeado), y <code>stat/voucher</code> (inventario completo de vouchers). Los cruza contra <code>umacauth.txt</code>, imprime un reporte de dos secciones (Autorizados, Vouchers) y ofrece cinco acciones interactivas de limpieza. <br>
      <br>
      Registra en <code>/var/log/uaudit.log</code>. <br>
      <br> Lee las credenciales de <code>/etc/uhotspot/uhotspot.conf</code>. Variables requeridas: <code>UNIFI_CONTROLLER_URL</code>, <code>UNIFI_USERNAME</code>, <code>UNIFI_PASSWORD</code>, <code>HOTSPOT_ESSID</code>. Opcional: <code>UNIFI_SITE</code> (default <code>default</code>).
    </td>
  </tr>
</table>

##### Action details

|  |  |
|---|---|
| **Delete unused vouchers** — Removes vouchers with `used=0` (never activated). Safe — no sessions to clean. | **Delete unused vouchers** — Elimina vouchers con `used=0` (nunca activados). Seguro — no hay sesiones que limpiar. |
| **Forget clients no voucher** — Forgets guests who connected to portal but never submitted a voucher. Only affects clients not currently on the SSID and with no voucher record. | **Forget clients no voucher** — Olvida invitados que se conectaron al portal pero nunca ingresaron un voucher. Solo afecta clientes no conectados actualmente al SSID y sin registro de voucher. |
| **Delete expired vouchers** — Deletes vouchers past `end_time`, then unauthorizes active sessions and forgets all client history linked to them. | **Delete expired vouchers** — Elimina vouchers cuya `end_time` ya pasó, luego desautoriza sesiones activas y olvida todo el historial de clientes vinculados. |
| **Revoke by voucher code** — Surgical revocation: delete voucher (if exists), unauthorize active sessions, forget all client history for that code. Addresses an observed UniFi inconsistency: when a voucher is manually deleted from the UniFi UI, `stat/guest` still retains session records with that `voucher_code`, allowing affected clients to reconnect without re-entering a code. This action cleans everything regardless of whether the voucher still exists in `stat/voucher` or not. | **Revoke by voucher code** — Revocación quirúrgica: elimina el voucher (si existe), desautoriza sesiones activas, olvida todo el historial de clientes para ese código. Aborda una inconsistencia observada en UniFi: cuando se elimina manualmente un voucher desde la UI de UniFi, `stat/guest` retiene registros de sesión con ese `voucher_code`, permitiendo que los clientes afectados se reconecten sin volver a ingresar un código. Esta acción limpia todo independientemente de si el voucher aún existe en `stat/voucher` o no. |
| **Purge everything** — DESTROYS all vouchers, disconnects all active guests, erases all client history. Requires typing `YES` to confirm. This action cannot be undone. | **Purge everything** — DESTRUYE todos los vouchers, desconecta todos los invitados activos, borra todo el historial de clientes. Requiere escribir `YES` para confirmar. Esta acción no se puede deshacer. |

```bash
sudo bash /etc/uhotspot/tools/uaudit.sh
```

Report:

```text
UniFi Clients Audit - starting, please wait...
  stat/sta     -> ok    (5 entries)
  stat/guest   -> ok    (3 entries)
  stat/voucher -> ok    (2 entries)

=======================================================================
 AUTHORIZED — umacauth.txt
=======================================================================
MAC                IP              CODE        STATUS  EXPIRES      ON
02:00:00:aa:bb:01  192.168.20.101  0000000001  MULTI   08-02 15:04  NO
02:00:00:aa:bb:02  192.168.20.102  0000000001  MULTI   08-02 15:04  NO
02:00:00:aa:bb:03  192.168.20.103  0000000002  VALID   08-02 16:20  YES
=======================================================================
 VOUCHERS — stat/voucher
=======================================================================
CODE        STATUS        DURATION  QUOTA  USED  EXPIRES
0000000002  USED_MULTIPL  2160h     5      2     08-02 21:17
0000000001  USED_MULTIPL  2160h     6      5     07-29 18:59

Audit complete. Log saved to: /var/log/uaudit.log

=======================================================================
 AVAILABLE ACTIONS
=======================================================================
  [1] Delete unused vouchers    - remove vouchers never activated
  [2] Forget clients no voucher  - connected to portal but never used one
  [3] Delete expired vouchers   - remove expired vouchers + forget their clients
  [4] Revoke by voucher code    - surgical invalidation by code (UniFi workaround)
  [5] Purge everything          - DELETE all vouchers and history (DESTRUCTIVE)
  [q] Quit

  Your choice:
```

### ucheck.sh

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>ucheck.sh</b> -- Interactive diagnostic tool that verifies the presence and consistency of MAC addresses across every DHCP/ACL data source used by <code>pydhcpd</code> and <code>uhotspot</code>: <code>umacauth.txt</code>, <code>ugrace.txt</code>, <code>blockdhcp.txt</code>, <code>acl_mac/*.txt</code>, <code>pydhcpd.leases</code> and (for option 5) the UniFi controller's <code>stat/sta</code>. Launched with no arguments, it presents a menu with five operations:
      <ul>
        <li><b>Check MAC</b> -- inspect a single MAC across all data sources and flag contradictory states (e.g. a MAC present in both <code>blockdhcp</code> and <code>acl_mac</code>). When the MAC is in the grace period, it also prints the remaining time before promotion to <code>blockdhcp</code>.</li>
        <li><b>Grace period status</b> -- list every MAC currently in <code>ugrace.txt</code> with IP, hostname and time remaining, colored by urgency (red &lt; 2 h, yellow &lt; 6 h, green otherwise).</li>
        <li><b>Consistency check + system summary</b> -- iterate over every MAC found in any source, print only those that violate a consistency rule, and finish with a per-state population summary (grace, blocked, ACL permanent, hotspot, active leases, total warnings).</li>
        <li><b>Search by IP or hostname</b> -- resolve an IP or hostname to its MAC(s) by scanning all sources, then run the full per-MAC consistency check on each match.</li>
        <li><b>UniFi: unauthorized clients on the ESSID</b> -- query the UniFi controller's <code>stat/sta</code> endpoint and list clients connected to the configured hotspot ESSID that UniFi has not authorized.</li>
      </ul>
      Exits <code>0</code> on normal termination, <code>2</code> if not run as root. Requires root because the underlying files are owned by <code>root</code>/<code>pydhcpd</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>ucheck.sh</b> -- Herramienta interactiva de diagnostico que verifica la presencia y consistencia de direcciones MAC en todas las fuentes de datos DHCP/ACL usadas por <code>pydhcpd</code> y <code>uhotspot</code>: <code>umacauth.txt</code>, <code>ugrace.txt</code>, <code>blockdhcp.txt</code>, <code>acl_mac/*.txt</code>, <code>pydhcpd.leases</code> y (para la opcion 5) el <code>stat/sta</code> del controlador UniFi. Lanzada sin argumentos, presenta un menu con cinco operaciones:
      <ul>
        <li><b>Check MAC</b> -- inspecciona una sola MAC en todas las fuentes y marca estados contradictorios (ej. una MAC presente en <code>blockdhcp</code> y <code>acl_mac</code> al mismo tiempo). Si la MAC esta en periodo de gracia, tambien imprime el tiempo restante antes de promocion a <code>blockdhcp</code>.</li>
        <li><b>Grace period status</b> -- lista cada MAC actualmente en <code>ugrace.txt</code> con IP, hostname y tiempo restante, coloreado por urgencia (rojo &lt; 2 h, amarillo &lt; 6 h, verde en otro caso).</li>
        <li><b>Consistency check + system summary</b> -- itera sobre cada MAC encontrada en cualquier fuente, imprime solo las que violan alguna regla de consistencia, y termina con un resumen por estado (gracia, bloqueadas, ACL permanente, hotspot, leases activos, total de advertencias).</li>
        <li><b>Search by IP or hostname</b> -- resuelve una IP o hostname a su(s) MAC(s) escaneando todas las fuentes, y luego corre el check completo de consistencia por cada coincidencia.</li>
        <li><b>UniFi: unauthorized clients on the ESSID</b> -- consulta el endpoint <code>stat/sta</code> del controlador UniFi y lista los clientes conectados al ESSID configurado del hotspot que UniFi no ha autorizado.</li>
      </ul>
      Sale con <code>0</code> en terminacion normal, <code>2</code> si no se ejecuta como root. Requiere root porque los archivos subyacentes pertenecen a <code>root</code>/<code>pydhcpd</code>.
    </td>
  </tr>
</table>

```bash
sudo bash /etc/uhotspot/tools/ucheck.sh
```

```text
########################################
#     ucheck -- MAC Diagnostic Tool    #
########################################
  1. Check MAC
  2. Grace period status
  3. Consistency check + system summary
  4. Search by IP or hostname
  5. UniFi: unauthorized clients on the ESSID
  6. Exit
  Select option [1-6]:
```

<b>Option 1 -- Check MAC</b>

```text
Select option [1-6]: 1

  Enter MAC address (XX:XX:XX:XX:XX:XX): 02:00:00:aa:bb:01
=== 02:00:00:aa:bb:01 ===
  umacauth.txt:   N
  ugrace.txt:     Y
  blockdhcp.txt:     N
  acl_mac/*.txt:     N
  pydhcpd.leases:    N
  Grace expires in : 6h 39m
  [i] In ugrace without active lease (normal -- short pool lease / limited range)
```

<b>Option 2 -- Grace period status</b>

```text
Select option [1-6]: 2
  MAC                  IP                 NAME                      EXPIRES IN
  ---------------------------------------------------------------------------
  02:00:00:aa:bb:01    192.168.20.236     laptop-example-01         6h 40m
  02:00:00:aa:bb:02    192.168.20.231     desktop-example-02        5h 55m
  02:00:00:aa:bb:03    192.168.20.235     pc-example-03             9h 40m
  02:00:00:aa:bb:04    192.168.20.234     no_name_example04         7h 40m
  02:00:00:aa:bb:05    192.168.20.238     phone-example-05          23h 33m
  Total: 5  |  Expired: 0  |  Active: 5
```

<b>Option 3 -- Consistency check + system summary</b>

```text
Select option [1-6]: 3
  Collecting all MACs from all data sources...
=== SYSTEM SUMMARY ===
  MACs found total  : 197
  Grace period      : 21
  Blocked           : 19
  ACL permanent     : 141
  Hotspot auth      : 14
  Active leases     : 2
  Warnings          : 0
```

<b>Option 4 -- Search by IP or hostname</b>

```text
Select option [1-6]: 4
  Enter IP address or hostname: 192.168.20.55
  Searching for: 192.168.20.55
  Found 1 MAC(s):
=== 02:00:00:aa:bb:99 ===
  umacauth.txt:   N
  ugrace.txt:     N
  blockdhcp.txt:     N
  acl_mac/*.txt:     Y
        /etc/acl/acl_mac/mac-proxy.txt
  pydhcpd.leases:    N
```

<b>Option 5 -- UniFi: unauthorized clients on the ESSID</b>

```text
Select option [1-6]: 5
  Connecting to https://192.168.0.1:8443...

  === Clients on hotspot-example NOT authorized by UniFi ===

  MAC                  HOSTNAME                  IP                 LAST_SEEN
  --------------------------------------------------------------------------------
  02:00:00:aa:bb:07    no-hostname               192.168.20.240     1752700000
```

##### Consistency rules applied

|  |  |
|---|---|
| **Blocked** -- must appear in `blockdhcp.txt` only. Warns if also in `acl_mac`, `ugrace`, or `leases` | **Bloqueada** -- debe aparecer solo en `blockdhcp.txt`. Advierte si tambien esta en `acl_mac`, `ugrace` o `leases` |
| **Grace period** -- `ugrace` present, `leases` may be absent briefly (60 s pool lease, limited range) | **Periodo de gracia** -- `ugrace` presente, `leases` puede estar ausente momentaneamente (lease de pool de 60 s, rango limitado) |
| **ACL permanent** -- `acl_mac` present, must NOT be in `blockdhcp` | **ACL permanente** -- `acl_mac` presente, NO debe estar en `blockdhcp` |
| **Hotspot auth** -- `umacauth` present, must NOT remain in `ugrace` (removed by `clean_grace_list` once promoted; briefly both right after promotion, until the next reload, is expected) | **Hotspot autenticado** -- `umacauth` presente, NO debe permanecer en `ugrace` (removida por `clean_grace_list` al ser promovida; que este brevemente en ambas justo tras la promocion, hasta el proximo reload, es esperado) |

### ualert

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>ualert.sh</b> is an <b>optional</b>, standalone alert watcher. It tails <code>/var/log/uhotspot.log</code> in real time and sends a push notification via <a href="https://ntfy.sh">ntfy.sh</a> on two kinds of events: (1) loss of connectivity to the UniFi controller, after <code>API_FAIL_THRESHOLD</code> consecutive cycles (default 3), followed by a recovery notice once it's back; and (2) any other <code>ERROR</code> or <code>WARNING</code> line in the shared log (from <code>uhotspotd.sh</code> or the <code>ureload.sh</code>/<code>uleases.sh</code>/<code>uiptables.sh</code> chain) — fires immediately, no threshold.
      <br><br>
      Runs as its own systemd service (<code>ualert.service</code>), independent of <code>uhotspotd.sh</code> — it never reads or modifies the daemon or its source, only tails the log file it already writes. <code>uhotspotd.sh</code> stays byte-identical to upstream whether <code>ualert</code> is installed or not, and the daemon runs the same with or without it.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>ualert.sh</b> es un vigilante de alertas <b>opcional</b> e independiente. Sigue <code>/var/log/uhotspot.log</code> en tiempo real y envia una notificacion push via <a href="https://ntfy.sh">ntfy.sh</a> ante dos tipos de eventos: (1) perdida de conectividad con el controlador UniFi, tras <code>API_FAIL_THRESHOLD</code> ciclos consecutivos (default 3), seguido de un aviso de recuperacion cuando vuelve; y (2) cualquier otra linea <code>ERROR</code> o <code>WARNING</code> en el log compartido (de <code>uhotspotd.sh</code> o la cadena <code>ureload.sh</code>/<code>uleases.sh</code>/<code>uiptables.sh</code>) -- dispara de inmediato, sin umbral.
      <br><br>
      Corre como su propio servicio systemd (<code>ualert.service</code>), independiente de <code>uhotspotd.sh</code> -- nunca lee ni modifica el daemon ni su codigo fuente, solo sigue el archivo de log que ya escribe. <code>uhotspotd.sh</code> se mantiene identico al original este o no instalado <code>ualert</code>, y el daemon funciona igual con o sin el.
    </td>
  </tr>
</table>

<p align="center">
  <a href="https://github.com/maravento/uhotspot"><img src="https://raw.githubusercontent.com/maravento/uhotspot/master/img/uhotspotalert.png" width="50%"></a>
</p>
<p align="center"><i>Push notifications via ntfy.sh — <a href="#real-example">See Real Example</a></i></p>
<p align="center"><i>Notificaciones push vía ntfy.sh — <a href="#real-example">Ver sección Real Example</a></i></p>

**Install:**

```bash
sudo /etc/uhotspot/tools/ualert.sh install
```

```text
==================================
Installing ualert (uhotspot alert)
==================================

Added NTFY_TOPIC, API_FAIL_THRESHOLD and STARTUP_GRACE_SECONDS to /etc/uhotspot/uhotspot.conf
Deploying script to /etc/uhotspot/tools/ualert.sh...
Writing systemd unit (/etc/systemd/system/ualert.service)...

✓ Installed and started. Check with: systemctl status ualert

==================================
 ntfy topic: uhotspot-alert-x7k2m9qv
==================================
Install the free 'ntfy' app (Android/iOS) and subscribe to the
topic above to start receiving alerts on this device.
```

**Uninstall:**

```bash
sudo /etc/uhotspot/tools/ualert.sh uninstall
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Detection logic:</b> Successful <code>uhotspotd</code> cycles are silent (no log output), so there is no positive "cycle OK" line to anchor on. Instead, <code>ualert.sh</code> anchors on <code>"Could not load vouchers"</code> -- a line <code>load_all_vouchers()</code> logs exactly once per cycle when the controller is unreachable. Two such lines less than <code>GAP_LIMIT</code> apart count as consecutive failing cycles; a larger gap means cycles succeeded silently in between, and the streak resets (the same <code>GAP_LIMIT</code> is also the read timeout used to detect recovery). <code>GAP_LIMIT = POLL_INTERVAL + 3*API_MAX_TIME + MARGIN</code> (default <code>20 + 3*30 + 10 = 120s</code>) -- the <code>3*API_MAX_TIME</code> term covers the worst case of a failed cycle still making up to three 30s-capped API calls (vouchers, guest, sta) before it ends.
      <br><br>
      Any other line starting with <code>ERROR:</code> or <code>WARNING:</code> fires immediately, no threshold -- the log already classifies severity (<code>"TIMESTAMP LEVEL: message"</code>), shared by <code>uhotspotd.sh</code> and the <code>ureload.sh</code>/<code>uleases.sh</code>/<code>uiptables.sh</code> chain. Excludes lines already covered by the connectivity streak above (so it still waits for the threshold, not the first failure) and <code>"cycle lock held unexpectedly"</code> (expected, not a bug).
      <br><br>
      <b>Startup grace:</b> <code>ualert.sh</code> itself starts at boot (systemd). If the connectivity threshold is reached while <code>uhotspotd.service</code> has been active for less than <code>STARTUP_GRACE_SECONDS</code>, the alert is suppressed — UniFi Network/UniFi OS can take a while to come back up after a reboot, and the daemon's very first cycles fail before the controller is even ready to answer. Checked against `uhotspotd`'s own start time (via systemd), not `ualert`'s — so this applies correctly whether the whole machine rebooted or just `uhotspotd` restarted on its own. A real outage later on still alerts at the normal threshold, unaffected.
      <br><br>
      This only covers the <code>run_cycle</code> connectivity streak. The daemon's own <em>initial</em> login (before the first cycle even runs) is handled separately inside `uhotspotd.sh` itself, using the same `STARTUP_GRACE_SECONDS` window — see the "Daemon Cycle" section below. Startup login retries log at `INFO`, not `ERROR`, so they never reach this catch-all in the first place.
      <br><br>
      <b>Recovery notice guard:</b> a "recovered" notice fires only if <code>uhotspotd.service</code> is still active when the <code>GAP_LIMIT</code> silence window elapses. Silence has two indistinguishable causes — cycles actually recovered, or the daemon stopped writing to the log entirely (manual stop, crash, start-limit-hit) — and without this check the second case would still send a false "recovered" notice while the controller could still be down and the daemon not even running.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Lógica de detección:</b> Los ciclos exitosos de <code>uhotspotd</code> son silenciosos (sin salida en el log), por lo que no hay una linea positiva de "ciclo OK" en la cual anclarse. En cambio, <code>ualert.sh</code> se ancla en <code>"Could not load vouchers"</code> -- una linea que <code>load_all_vouchers()</code> registra exactamente una vez por ciclo cuando el controlador es inalcanzable. Dos de esas lineas separadas por menos de <code>GAP_LIMIT</code> cuentan como ciclos fallidos consecutivos; un salto mayor implica que hubo ciclos exitosos silenciosos en el medio, y la racha se reinicia (el mismo <code>GAP_LIMIT</code> es también el timeout de lectura usado para detectar la recuperación). <code>GAP_LIMIT = POLL_INTERVAL + 3*API_MAX_TIME + MARGIN</code> (default <code>20 + 3*30 + 10 = 120s</code>) -- el término <code>3*API_MAX_TIME</code> cubre el peor caso de un ciclo fallido que aún así hace hasta tres llamadas API con límite de 30s (vouchers, guest, sta) antes de terminar.
      <br><br>
      Cualquier otra linea que empiece con <code>ERROR:</code> o <code>WARNING:</code> dispara de inmediato, sin umbral -- el log ya clasifica la severidad (<code>"TIMESTAMP NIVEL: mensaje"</code>), compartido entre <code>uhotspotd.sh</code> y la cadena <code>ureload.sh</code>/<code>uleases.sh</code>/<code>uiptables.sh</code>. Excluye las lineas ya cubiertas por la racha de conectividad de arriba (para que siga esperando el umbral, no el primer fallo) y <code>"cycle lock held unexpectedly"</code> (esperado, no es un bug).
      <br><br>
      <b>Gracia de arranque:</b> <code>ualert.sh</code> arranca junto con el sistema (systemd). Si el umbral de conectividad se cumple mientras <code>uhotspotd.service</code> lleva menos de <code>STARTUP_GRACE_SECONDS</code> activo, la alerta se suprime -- UniFi Network/UniFi OS puede tardar en volver a estar disponible tras un reinicio, y los primeros ciclos del daemon fallan antes de que el controlador siquiera esté listo para responder. Se verifica contra el propio inicio de `uhotspotd` (vía systemd), no el de `ualert` -- asi aplica correctamente ya sea que se haya reiniciado el equipo completo o solo `uhotspotd` por su cuenta. Un fallo real más adelante sigue alertando con el umbral normal, sin verse afectado.
      <br><br>
      Esto solo cubre la racha de conectividad de `run_cycle`. El login <em>inicial</em> del daemon (antes de que corra el primer ciclo) se maneja aparte, dentro del propio `uhotspotd.sh`, usando la misma ventana `STARTUP_GRACE_SECONDS` -- ver la sección "Daemon Cycle" más abajo. Los reintentos de login de arranque quedan en nivel `INFO`, no `ERROR`, así que nunca llegan a este catch-all.
      <br><br>
      <b>Verificación antes del aviso de recuperación:</b> un aviso de "recovered" solo se envía si `uhotspotd.service` sigue activo cuando se cumple la ventana de silencio `GAP_LIMIT`. El silencio tiene dos causas indistinguibles -- los ciclos realmente se recuperaron, o el daemon dejó de escribir en el log por completo (detención manual, crash, start-limit-hit) -- y sin este chequeo el segundo caso igual mandaría un falso "recovered" mientras el controlador podría seguir caído y el daemon ni siquiera estar corriendo.
    </td>
  </tr>
</table>

#### Real Example

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      A brief controller outage (restart/update) triggers exactly the sequence shown in the screenshot above. The daemon degrades gracefully on every failed cycle — <code>skipping sessions</code>/<code>skipping revoke</code> — instead of acting on partial data, alerts once the 3-cycle threshold is hit, and re-authenticates automatically once the controller is reachable again:
    </td>
    <td style="width: 50%; vertical-align: top;">
      Una caída breve del controlador (reinicio/actualización) dispara exactamente la secuencia del pantallazo de arriba. El daemon se degrada de forma segura en cada ciclo fallido — <code>skipping sessions</code>/<code>skipping revoke</code> — en vez de actuar con datos parciales, alerta al llegar al umbral de 3 ciclos, y se re-autentica solo apenas el controlador vuelve a responder:
    </td>
  </tr>
</table>

```text
2026-07-12 00:40:26 WARNING: API GET https://<controller_ip>:11443/proxy/network/api/s/default/stat/voucher → HTTP 502
2026-07-12 00:40:26 WARNING: Could not load vouchers (rc=empty)
2026-07-12 00:40:28 WARNING: API GET https://<controller_ip>:11443/proxy/network/api/s/default/stat/guest → HTTP 000
2026-07-12 00:40:28 INFO: stat/guest unavailable — skipping sessions
2026-07-12 00:40:29 WARNING: API GET https://<controller_ip>:11443/proxy/network/api/s/default/stat/sta → HTTP 000
2026-07-12 00:40:29 INFO: stat/sta unavailable — skipping revoke
[... cycles keep failing every ~POLL_INTERVAL, same pattern ...]
2026-07-12 00:41:11 WARNING: Could not load vouchers (rc=empty)
2026-07-12 00:41:11 ALERT: sent — 3 consecutive cycle failures, latest at 2026-07-12 00:41:11
[... failures continue while the controller is still down ...]
2026-07-12 00:42:43 INFO: Session expired — re-authenticating
2026-07-12 00:42:43 INFO: UniFi login OK
2026-07-12 00:43:13 ALERT: recovery notice sent
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The first <code>HTTP 502</code> (proxy up, backend not yet) followed immediately by <code>HTTP 000</code> on every subsequent request (connection itself unreachable) is the fingerprint of a UniFi OS controller restart, not a network/firewall problem on the <code>uhotspot</code> side — worth checking the controller's own system log for that window if it happens outside a planned update.
      <br><br>
      A <b>server reboot</b> shows a different, unrelated-looking pattern instead — quiet <code>INFO</code>-level login retries while UniFi OS is still booting, followed by a login success, followed by a few data-endpoint failures before the backend settles — with no alert firing, since <code>ualert.sh</code> is also inside its own startup grace window at that point. See <a href="#uhotspotd">uhotspotd</a> above for that log sequence in full.
    </td>
    <td style="width: 50%; vertical-align: top;">
      El primer <code>HTTP 502</code> (proxy activo, backend aún no) seguido de inmediato por <code>HTTP 000</code> en cada petición posterior (la conexión misma es inalcanzable) es la firma de un reinicio del controlador UniFi OS, no un problema de red/firewall del lado de <code>uhotspot</code> — vale la pena revisar el log propio del sistema del controlador en esa ventana si ocurre fuera de una actualización planificada.
      <br><br>
      Un <b>reinicio del servidor</b> muestra un patrón distinto y aparentemente no relacionado — reintentos de login silenciosos en nivel <code>INFO</code> mientras UniFi OS todavía está arrancando, seguidos de un login exitoso, seguidos de algunos fallos en los endpoints de datos antes de que el backend se asiente — sin que se dispare ninguna alerta, ya que <code>ualert.sh</code> también está dentro de su propia ventana de gracia de arranque en ese momento. Ver <a href="#uhotspotd">uhotspotd</a> arriba para esa secuencia de log completa.
    </td>
  </tr>
</table>

**Configuration variables (in `uhotspot.conf`, written automatically by `install`):**

| Variable | Default | Description | Descripción |
|----------|---------|-------------|-------------|
| `NTFY_TOPIC` | *(auto-generated)* | ntfy.sh topic name, e.g. `uhotspot-alert-x7k2m9qv`. Treat as a shared secret — anyone who knows it can publish to it. Never overwritten by a re-install. | Nombre del topic de ntfy.sh, ej. `uhotspot-alert-x7k2m9qv`. Trátelo como un secreto compartido — cualquiera que lo conozca puede publicar en él. Nunca se sobrescribe en una reinstalación. |
| `API_FAIL_THRESHOLD` | 3 | Consecutive failing cycles required before sending an alert | Ciclos fallidos consecutivos requeridos antes de enviar una alerta |
| `STARTUP_GRACE_SECONDS` | 120 | Shared by two mechanisms: (1) `uhotspotd.sh` itself retries its initial UniFi login quietly for up to this many seconds before giving up and exiting for real — see `main()` in `uhotspotd.sh`; (2) `ualert.sh` suppresses the connectivity alert while `uhotspotd.service` has been active for less than this long. Both exist because UniFi Network/UniFi OS can take a while to come back up after a reboot, and this host often boots alongside it. Written to `uhotspot.conf` by `ualert.sh install`, but `uhotspotd.sh` reads it with its own built-in default (120) even if `ualert` was never installed. This is an estimate, not a measured value: tune it to how long *your* UniFi Network/UniFi OS instance actually takes to come back up after a restart. Only the startup window is affected — a real outage later in the day still alerts/retries at the normal thresholds, undiminished. | Compartido por dos mecanismos: (1) `uhotspotd.sh` reintenta su login inicial a UniFi en silencio hasta por esta cantidad de segundos antes de rendirse y salir de verdad — ver `main()` en `uhotspotd.sh`; (2) `ualert.sh` suprime la alerta de conectividad mientras `uhotspotd.service` ha estado activo por menos de este tiempo. Ambos existen porque UniFi Network/UniFi OS puede tardar en volver tras un reinicio, y este host suele arrancar junto con él. Escrito en `uhotspot.conf` por `ualert.sh install`, pero `uhotspotd.sh` lo lee con su propio default incorporado (120) aunque `ualert` nunca se haya instalado. Esto es una estimación, no un valor medido: ajústelo a lo que realmente tarda *su* instancia de UniFi Network/UniFi OS en volver tras un reinicio. Solo afecta la ventana de arranque — un corte real más tarde en el día sigue alertando/reintentando en los umbrales normales, sin disminución. |

> `POLL_INTERVAL` is read from the same `uhotspot.conf` used by `uhotspotd.sh` (falls back to 20 if unset) — no separate configuration needed.
>
> `POLL_INTERVAL` se lee del mismo `uhotspot.conf` que usa `uhotspotd.sh` (default 20 si no esta definido) -- no requiere configuracion aparte.

### uwatch

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>uwatch.sh</b> is an <b>optional</b>, standalone services watchdog. Runs every 5 minutes via cron and checks every service <code>uhotspot</code> depends on, restarting whichever is down: <code>uhotspotd.service</code> (always), <code>ualert.service</code> (only if installed), and the UniFi backend (<code>uosserver.service</code> for <code>UNIFI_TYPE=unifi-os</code>, or <code>unifi.service</code> for <code>classic</code>). Each check is fully independent — one check's failure never skips or blocks the others in the same run.
      <br><br>
      Standalone — never reads or modifies <code>uhotspotd.sh</code>, only manages services via <code>systemctl</code>. Writes to the same shared <code>/var/log/uhotspot.log</code> as the rest of <code>uhotspot</code> (no separate log file or logrotate of its own). Silent on a healthy run — nothing is logged unless a check finds a problem or takes a fix action.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>uwatch.sh</b> es un vigilante de servicios <b>opcional</b> e independiente. Corre cada 5 minutos por cron y verifica cada servicio del que depende <code>uhotspot</code>, reiniciando el que esté caído: <code>uhotspotd.service</code> (siempre), <code>ualert.service</code> (solo si está instalado), y el backend de UniFi (<code>uosserver.service</code> para <code>UNIFI_TYPE=unifi-os</code>, o <code>unifi.service</code> para <code>classic</code>). Cada chequeo es completamente independiente — el fallo de uno nunca salta ni bloquea a los demás en la misma corrida.
      <br><br>
      Independiente — nunca lee ni modifica <code>uhotspotd.sh</code>, solo gestiona servicios vía <code>systemctl</code>. Escribe al mismo <code>/var/log/uhotspot.log</code> compartido con el resto de <code>uhotspot</code> (sin log ni logrotate propio). Silencioso en una corrida sana — no registra nada salvo que un chequeo encuentre un problema o tome una acción de reparación.
    </td>
  </tr>
</table>

**Install:**

```bash
sudo /etc/uhotspot/tools/uwatch.sh install
```

```text
==================================
Installing uwatch (uhotspot services watchdog)
==================================

Deploying script to /etc/uhotspot/tools/uwatch.sh...
Cron entry registered: */5 * * * * /etc/uhotspot/tools/uwatch.sh

✓ Installed. First run happens on the next 5-minute mark.
  Check the log with: tail -f /var/log/uhotspot.log
```

**Uninstall:**

```bash
sudo /etc/uhotspot/tools/uwatch.sh uninstall
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>UniFi backend check:</b> a plain <code>systemctl is-active</code> only proves the process is up, not that the application itself is healthy — the container's (or subprocess's) embedded MongoDB can fail to come up while the process keeps running, leaving every real API call broken. So once the service is confirmed active, <code>uwatch.sh</code> performs the same real login <code>uhotspotd.sh</code> itself relies on (<code>UNIFI_USERNAME</code>/<code>UNIFI_PASSWORD</code> from <code>uhotspot.conf</code>, credentials via <code>jq</code> env and payload via <code>curl</code> stdin — never in argv). <code>HTTP 200</code> = healthy. <code>HTTP 000</code> (unreachable) or <code>5xx</code> (server error) = unresponsive, restarts the service. Any <code>4xx</code> means credentials were rejected but the service itself answered — logged as a warning, <b>no restart</b> (a restart doesn't fix a wrong password in <code>uhotspot.conf</code>, and could trigger UniFi's own login rate-limiting). If <code>UNIFI_USERNAME</code>/<code>UNIFI_PASSWORD</code> aren't set, falls back to a process/port-only check instead of skipping it.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Chequeo del backend UniFi:</b> un simple <code>systemctl is-active</code> solo prueba que el proceso está arriba, no que la aplicación esté sana — el MongoDB embebido del contenedor (o subproceso) puede fallar al iniciar mientras el proceso sigue corriendo, dejando rota cualquier llamada real a la API. Por eso, una vez confirmado que el servicio está activo, <code>uwatch.sh</code> hace el mismo login real que usa <code>uhotspotd.sh</code> (<code>UNIFI_USERNAME</code>/<code>UNIFI_PASSWORD</code> de <code>uhotspot.conf</code>, credenciales vía env de <code>jq</code> y payload vía stdin de <code>curl</code> — nunca en argv). <code>HTTP 200</code> = sano. <code>HTTP 000</code> (inalcanzable) o <code>5xx</code> (error de servidor) = no responde, reinicia el servicio. Cualquier <code>4xx</code> significa que las credenciales fueron rechazadas pero el servicio sí respondió — se registra como advertencia, <b>sin reiniciar</b> (un reinicio no corrige una contraseña mal escrita en <code>uhotspot.conf</code>, y podría activar el rate-limiting de login de UniFi). Si <code>UNIFI_USERNAME</code>/<code>UNIFI_PASSWORD</code> no están configuradas, cae de vuelta a un chequeo de solo proceso/puerto en vez de omitirlo.
    </td>
  </tr>
</table>

**Wrong password / Contraseña incorrecta:**

```text
2026-07-15 17:21:03 WARNING: credentials rejected (HTTP 403)
2026-07-15 17:21:03 Check uhotspot.conf - UOS itself is responding
```

**Normal operation / Operación normal:**

```text
(nothing — a healthy run writes no log lines / nada — una corrida sana no escribe líneas de log)
```

## LOGS

---

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>uhotspot.log</b> — All output from every component (<code>uhotspotd</code>, <code>ureload.sh</code>, <code>uleases.sh</code>, <code>uiptables.sh</code>) is unified in <code>/var/log/uhotspot.log</code> and rotated via <code>/etc/logrotate.d/uhotspot</code> (daily, 7 rotations, compressed). The log follows one rule throughout: <b>stay silent on no-op cycles, log once when something actually changes, always log errors and warnings</b>. Idle cycles (no ACL change) produce zero lines. <code>uhotspotd</code> classifies every line as <code>INFO:</code>, <code>WARNING:</code>, or <code>ERROR:</code>; <code>ureload.sh</code>, <code>uleases.sh</code>, and <code>uiptables.sh</code> only prefix genuine <code>WARNING:</code>/<code>ERROR:</code> conditions and otherwise log plain step messages — the Webmin viewer (<code>uhotspotmon.sh</code>) groups these unprefixed lines under a generic level so you can still tell "daemon-level event" apart from "reload-chain internals" at a glance. Each of the three sub-scripts announces its own boundaries with <code>"&lt;name&gt; start..."</code> / <code>"&lt;name&gt; done"</code> so you can tell which component produced which lines when several are nested in the same reload chain.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>uhotspot.log</b> — Toda la salida de cada componente (<code>uhotspotd</code>, <code>ureload.sh</code>, <code>uleases.sh</code>, <code>uiptables.sh</code>) se unifica en <code>/var/log/uhotspot.log</code> y se rota vía <code>/etc/logrotate.d/uhotspot</code> (diario, 7 rotaciones, comprimido). El log sigue una sola regla: <b>silencio en ciclos sin cambios, un registro cuando algo realmente cambia, y siempre errores y advertencias</b>. Los ciclos inactivos (sin cambio de ACL) no producen ninguna línea. <code>uhotspotd</code> clasifica cada línea como <code>INFO:</code>, <code>WARNING:</code> o <code>ERROR:</code>; <code>ureload.sh</code>, <code>uleases.sh</code> y <code>uiptables.sh</code> solo prefijan condiciones reales de <code>WARNING:</code>/<code>ERROR:</code> y el resto queda como mensajes de paso sin prefijo — el visor de Webmin (<code>uhotspotmon.sh</code>) agrupa estas líneas sin prefijo bajo un nivel genérico, para poder distinguir de un vistazo "evento de nivel daemon" de "maquinaria interna del reload". Cada uno de los tres sub-scripts anuncia su propio inicio y cierre con <code>"&lt;nombre&gt; start..."</code> / <code>"&lt;nombre&gt; done"</code>, para poder identificar qué componente produjo cada línea cuando varios quedan anidados dentro de la misma cadena de reload.
    </td>
  </tr>
</table>

```text
2026-07-01 06:47:35 INFO: New client 02:00:00:aa:bb:10 ip=192.168.0.231 hostname=no_name_fde07d34be → ugrace.txt
2026-07-01 06:47:35 INFO: process_new_leases → added 1 new client(s) to ugrace.txt
2026-07-01 06:47:35 INFO: ugrace.txt changed
2026-07-01 06:47:35 INFO: invoking /etc/uhotspot/core/ureload.sh
2026-07-01 06:47:35 ureload start...
2026-07-01 06:47:35 uleases start...
2026-07-01 06:47:36 expire_grace_entries: expired 02:00:00:aa:bb:11 (age=43346s) → blockdhcp
2026-07-01 06:47:36 expire_grace_entries: queued lease removal for 02:00:00:aa:bb:11
2026-07-01 06:47:40 ACL: blockdhcp=67 | proxy=105 | unlimited=35 | hotspot=17 | ugrace=8
2026-07-01 06:47:40 uleases done at: Wed Jul  1 06:47:40 -05 2026
2026-07-01 06:47:40 uiptables start...
2026-07-01 06:47:42 uiptables done at: Wed Jul  1 06:47:42 -05 2026
2026-07-01 06:47:42 ureload done at: Wed Jul  1 06:47:42 -05 2026
2026-07-01 06:47:42 STATS: vouchers=3 | authorized=17 | grace=8 | new_auth=0 | revoked=0
```

No client connected, no voucher redeemed, no grace entry expired? The log between two cycles is simply empty — nothing is written.

| Field | Type | Description | Descripción |
|---|---|---|---|
| `vouchers` | total | Vouchers currently in UniFi (`stat/voucher`) | Vouchers presentes en UniFi |
| `authorized` | total | MACs in `umacauth.txt` at end of cycle | MACs en `umacauth.txt` al final del ciclo |
| `grace` | total | MACs in `ugrace.txt` at end of cycle | MACs en `ugrace.txt` al final del ciclo |
| `new_auth` | delta | MACs processed by the sessions step this cycle: new promotions to `umacauth.txt` **and** voucher renewals of MACs already in it (only new promotions get kicked — see step 11) | MACs procesadas por el paso de sesiones en este ciclo: promociones nuevas a `umacauth.txt` **y** renovaciones de voucher de MACs ya presentes en él (solo las promociones nuevas reciben kick — ver paso 11) |
| `revoked` | delta | MACs removed from `umacauth.txt` this cycle (`authorized=false` in UniFi) | MACs eliminadas de `umacauth.txt` en este ciclo |

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>uleases output</b> — Written to <code>/var/log/uhotspot.log</code> (unified log). Only real state changes on <code>ugrace.txt</code> are logged: a MAC added on first contact, one expired to <code>blockdhcp.txt</code> after <code>BLOCKDHCP_GRACE_SECONDS</code>, or one removed by <code>clean_grace_list()</code> when found in another ACL list. Entries that are simply preserved during their grace period produce no output — nothing to log means nothing changed.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Salida de uleases</b> — Se escribe en <code>/var/log/uhotspot.log</code> (log unificado). Solo se registran cambios reales de estado sobre <code>ugrace.txt</code>: una MAC agregada al primer contacto, una expirada a <code>blockdhcp.txt</code> tras <code>BLOCKDHCP_GRACE_SECONDS</code>, o una removida por <code>clean_grace_list()</code> al encontrarse en otra lista ACL. Las entradas que simplemente se preservan durante su período de gracia no producen ninguna salida — nada que registrar significa que nada cambió.
    </td>
  </tr>
</table>

```text
2026-07-01 06:47:36 expire_grace_entries: expired 02:00:00:aa:bb:11 (age=43346s) → blockdhcp
2026-07-01 06:47:36 expire_grace_entries: queued lease removal for 02:00:00:aa:bb:11
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>UniFi controller access log</b> — Separate from <code>/var/log/uhotspot.log</code>. UniFi OS Server runs inside a Podman container (<code>uosserver</code>), so its own portal access log lives at <code>/data/unifi/logs/access.log</code> <b>inside that container</b>, not on the host. Useful to confirm whether a client's captive-portal probe actually reached the AP's native redirect (look for <code>ap=</code>, <code>id=</code>, <code>ssid=</code> in the URL — their absence means the hit didn't come from the AP redirect). It's a binary-ish log file, so use <code>grep -a</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Log de acceso del controlador UniFi</b> — Distinto de <code>/var/log/uhotspot.log</code>. UniFi OS Server corre dentro de un contenedor Podman (<code>uosserver</code>), así que su propio log de acceso al portal vive en <code>/data/unifi/logs/access.log</code> <b>dentro de ese contenedor</b>, no en el host. Útil para confirmar si el sondeo de portal cautivo de un cliente realmente llegó al redirect nativo del AP (busque <code>ap=</code>, <code>id=</code>, <code>ssid=</code> en la URL — su ausencia significa que el hit no vino del redirect del AP). Es un archivo de log cuasi-binario, use <code>grep -a</code>.
    </td>
  </tr>
</table>

```bash
# Tail live, filtering only captive-portal hits (/guest/)
sudo -u uosserver podman exec uosserver tail -f /data/unifi/logs/access.log \
    | grep --line-buffered -a "/guest/"

# Example line this produces (302 = AP redirect worked, params present):
# [2026-07-04T15:02:33,854-05:00] [ 192.168.0.231 -> portal-82 ] GET 200 3ms \
#   /guest/s/default/?ap=02:00:00:aa:bb:12&id=02:00:00:aa:bb:13&t=1783195353&url=http://netcts.cdn-apple.com%2F&ssid=EXAMPLE_SSID

# Search the full history for a specific client MAC (not IP — IPs rotate every DHCP renewal)
sudo -u uosserver podman exec uosserver grep -a "id=02:00:00:aa:bb:13" /data/unifi/logs/access.log

# Confirm the portal itself is reachable and serving (run from the gateway host)
sudo -u uosserver podman exec uosserver curl -v http://192.168.0.10:8880/guest/s/default/
```

## IMPORTANT

---

| Note | Description | Descripción |
|------|-----|-----|
| **Synchronization** | `uhotspot` depends on correct synchronization between UniFi Network, the DHCP server, and the user-maintained firewall script. It is not guaranteed to work on every Linux system. | `uhotspot` depende de la correcta sincronización entre UniFi Network, el servidor DHCP y el script firewall que mantiene el usuario. No se garantiza su funcionamiento en todos los sistemas Linux. |
| **Lease queue** | The script queues lease removals for MACs it manages (via `uqueue.txt`). Actual removal is performed by `uleases.sh` during its safe DHCP stop→modify→start cycle. Leases for hotspot MACs are short-lived by design. `uqueue.txt` is an internal working file consumed by both scripts, not a config variable or ACL — do not edit it manually. | El script encola remociones de leases para los MACs que gestiona (vía `uqueue.txt`). La remoción real la ejecuta `uleases.sh` durante su ciclo seguro de detener→modificar→arrancar DHCP. Los leases para MACs del hotspot son de corta vida por diseño. `uqueue.txt` es un archivo de trabajo interno que consumen ambos scripts, no una variable de configuración ni una ACL — no debe editarse manualmente. |
| **Firewall scope** | Both `ugrace.txt` and `umacauth.txt` clients must be reachable via your DHCP server. Only `umacauth.txt` clients should be granted full Internet by your firewall; grace-period clients (`macgrace` ipset) should only reach the captive portal ports. | Los clientes de `ugrace.txt` y `umacauth.txt` deben ser alcanzables por su servidor DHCP. Solo `umacauth.txt` debe tener Internet completo vía firewall; los clientes en período de gracia (ipset `macgrace`) solo deben llegar a los puertos del portal cautivo. |
| **Script header** | Read the script header before deploying — it documents the full flow and any newly added behavior. | Lea el header del script antes de desplegarlo — documenta el flujo completo y cualquier comportamiento recién añadido. |
| **Testing** | Always test in a non-production environment first. | Pruebe siempre en un entorno no productivo primero. |
| **WPAD/PAC** | `uleases.sh` generates `/etc/pydhcp/pydhcpd.conf` dynamically on every run. Set `WPAD_ENABLED=true` in `uhotspot.conf` to enable WPAD/PAC via DHCP option 252. Prerequisites: Apache2 with a VirtualHost on port 18100 serving a valid `wpad.pac` file. Set `WPAD_ENABLED=false` (default) to disable. The `option wpad` lines are written automatically on the next `uleases.sh` run. | `uleases.sh` genera `/etc/pydhcp/pydhcpd.conf` dinámicamente en cada ejecución. Establezca `WPAD_ENABLED=true` en `uhotspot.conf` para activar WPAD/PAC vía DHCP option 252. Requisitos: Apache2 con un VirtualHost en el puerto 18100 sirviendo un archivo `wpad.pac` válido. Establezca `WPAD_ENABLED=false` (por defecto) para desactivar. Las líneas `option wpad` se escriben automáticamente en la próxima ejecución de `uleases.sh`. |
| **WPAD/PAC scope** | `pydhcpd` is ACL-agnostic — when `WPAD_ENABLED=true` it sends DHCP option 252 to every client, including `mac-unlimited`. Since unlimited devices must never go through the proxy, `uiptables.sh` blocks them from reaching port 18100 (the PAC file) at the firewall level; the PAC's own `; DIRECT` fallback makes the browser proceed without a proxy for them. | `pydhcpd` no distingue ACLs — cuando `WPAD_ENABLED=true` envía la opción DHCP 252 a todos los clientes, incluyendo `mac-unlimited`. Como los dispositivos unlimited nunca deben pasar por el proxy, `uiptables.sh` les bloquea el acceso al puerto 18100 (el archivo PAC) a nivel de firewall; el fallback `; DIRECT` del propio PAC hace que el navegador siga sin proxy para ellos. |
| **ping-check** | `ping-check true` is enabled by default in the `pydhcpd.conf` generated by `uleases.sh`. The daemon pings each IP before an OFFER to detect conflicts. In environments with strict ICMP firewall rules the ping will always time out silently and have no effect. Set `PING_CHECK_ENABLED=false` in `uhotspot.conf` to disable it. | `ping-check true` está activado por defecto en el `pydhcpd.conf` generado por `uleases.sh`. El demonio hace ping a cada IP antes del OFFER para detectar conflictos. En entornos con reglas de firewall estrictas que bloquean ICMP el ping siempre expirará sin efecto. Establezca `PING_CHECK_ENABLED=false` en `uhotspot.conf` para desactivarlo. |

## LIMITATIONS

---

### UI

| Limitation | Description | Descripción |
|---|---|---|
| **UniFi UI inconsistencies** | The UniFi Network UI may display inconsistent or inaccurate information about guest clients. This does not affect operation. `uhotspotd` works exclusively from data obtained directly from the UniFi API — `stat/sta`, `stat/guest`, and `stat/voucher` — and is not influenced by what the UI chooses to display. | La UI de UniFi Network puede mostrar información inconsistente o incorrecta sobre los clientes invitados. Esto no afecta el funcionamiento. `uhotspotd` opera exclusivamente sobre datos obtenidos directamente de la API de UniFi — `stat/sta`, `stat/guest` y `stat/voucher` — y no se ve influenciado por lo que la UI decida mostrar. |
| **Portal detection latency** | A new client connecting to the SSID may wait roughly one `POLL_INTERVAL` cycle before the captive portal appears. Detection does not depend on `stat/sta` — `uhotspotd` scans `pydhcpd.leases` directly every cycle (the *new leases* step) and writes straight to `ugrace.txt`, which is what triggers the reload (`uleases.sh`) that updates the `macgrace` ipset. The client receives a pool DHCP lease immediately; this only works reliably if the pool lease (`min/default/max-lease-time`, set from `CLEANUP_INTERVAL` in `uhotspot.conf`) lasts longer than one full daemon cycle — if `CLEANUP_INTERVAL` is too tight relative to `POLL_INTERVAL` plus actual cycle execution time (API calls add latency beyond `POLL_INTERVAL` itself), and the client's OS does not renew its DHCP lease before expiry (some devices wait until the lease's hard deadline instead of renewing at ~50%), the lease can be purged by `pydhcpd`'s own cleanup loop before any cycle reads the file, and the client won't be detected until it requests DHCP again. | Un cliente nuevo que se conecta al SSID puede esperar aproximadamente un ciclo de `POLL_INTERVAL` antes de que aparezca el portal cautivo. La detección no depende de `stat/sta` — `uhotspotd` escanea `pydhcpd.leases` directamente en cada ciclo (el paso de *clientes nuevos*) y escribe directo en `ugrace.txt`, que es lo que dispara el reload (`uleases.sh`) que actualiza el ipset `macgrace`. El cliente recibe un lease DHCP de pool de inmediato; esto solo funciona de forma confiable si el lease del pool (`min/default/max-lease-time`, definido por `CLEANUP_INTERVAL` en `uhotspot.conf`) dura más que un ciclo completo del daemon — si `CLEANUP_INTERVAL` queda muy ajustado respecto a `POLL_INTERVAL` más el tiempo real de ejecución del ciclo (las llamadas API agregan latencia más allá del `POLL_INTERVAL` mismo), y el sistema operativo del cliente no renueva su lease DHCP antes de que expire (algunos dispositivos esperan hasta el límite exacto del lease en vez de renovar a ~50%), el reaper de `pydhcpd` puede purgar el lease antes de que algún ciclo alcance a leer el archivo, y el cliente no se detecta hasta que vuelva a pedir DHCP. |

### Mobile Device

> These are platform and device limitations, not defects in this project.
>
> Estas son limitaciones de plataforma y dispositivo, no defectos de este proyecto.

| Limitation | Limitación | Description | Descripción |
|------------|------------|-----|-----|
| **WPAD not supported** | **WPAD no soportado** | Android and iOS ignore DHCP option 252. The proxy must be configured manually on each device. | Android e iOS ignoran la opción DHCP 252. El proxy debe configurarse manualmente en cada dispositivo. |
| **Captive portal probes** | **Sondas del portal cautivo** | Android probes `connectivitycheck.gstatic.com`; iOS probes `captive.apple.com`. If blocked or intercepted, the device reports *"connected without internet"* even when the proxy works. Whitelist these in Squid without auth. | Android sondea `connectivitycheck.gstatic.com`; iOS sondea `captive.apple.com`. Si están bloqueados o interceptados, el dispositivo reporta *"conectado sin internet"* aunque el proxy funcione. Agréguelos a la whitelist de Squid sin autenticación. |
| **App proxy bypass** | **Apps que bypasean el proxy** | Most apps on Android and iOS bypass the system proxy and connect directly. Only browsers reliably honor a manual proxy. Without SSL bump, direct HTTPS traffic cannot be redirected. | La mayoría de las apps en Android e iOS bypasean el proxy del sistema y se conectan directamente. Solo los navegadores respetan de forma confiable un proxy manual. Sin SSL bump, el tráfico HTTPS directo no puede ser redirigido. |
| **MAC randomization** | **Aleatorización de MAC** | Android 10+ and iOS 14+ randomize the MAC per network by default. A randomized MAC will never match an ACL entry and will appear as unauthorized on every connection. Users must disable MAC randomization for the SSID before connecting. | Android 10+ e iOS 14+ aleatorizan la MAC por red por defecto. Una MAC aleatorizada nunca coincidirá con una entrada ACL y aparecerá como no autorizada en cada conexión. El usuario debe deshabilitar la aleatorización de MAC para el SSID antes de conectarse. |

### Access Control

> This is a structural limitation of MAC-based classification, not a code defect — see mitigation below.
>
> Esta es una limitación estructural de la clasificación basada en MAC, no un defecto de código — ver mitigación abajo.

| Limitation | Limitación | Description | Descripción |
|------------|------------|-----|-----|
| **`mac-*.txt` IP range is administrator-defined, not a config variable** | **El rango de IP de `mac-*.txt` es decisión del administrador, no una variable de configuración** | `uhotspot.conf` only defines two IP ranges: `HOTSPOT_RANGE_START`/`HOTSPOT_RANGE_END` for `umacauth.txt`, and `SERV_INI_RANGE_BLOCK`/`SERV_END_RANGE_BLOCK` for the pydhcp pool (`ugrace.txt`/`blockdhcp.txt`). `mac-*.txt` files (`mac-proxy.txt`, `mac-unlimited.txt`) don't exist by default — `usetup.sh` only creates the `/etc/acl/acl_mac` directory; the administrator creates these files and picks their IPs manually, with no dedicated range enforced by `uhotspot.conf` itself. `uleases.sh`'s `check_acl_conflicts()` validates this on every run: any `mac-*.txt` IP landing inside either reserved range aborts the reload with a specific `ERROR:` log line and a desktop notification — see [uleases](#uleases) below for examples — but the safest practice is keeping every `mac-*.txt` IP outside both ranges from the start. | `uhotspot.conf` solo define dos rangos de IP: `HOTSPOT_RANGE_START`/`HOTSPOT_RANGE_END` para `umacauth.txt`, y `SERV_INI_RANGE_BLOCK`/`SERV_END_RANGE_BLOCK` para el pool de pydhcp (`ugrace.txt`/`blockdhcp.txt`). Los archivos `mac-*.txt` (`mac-proxy.txt`, `mac-unlimited.txt`) no existen por defecto — `usetup.sh` solo crea el directorio `/etc/acl/acl_mac`; el administrador crea estos archivos y elige sus IPs manualmente, sin rango dedicado impuesto por `uhotspot.conf`. `check_acl_conflicts()` en `uleases.sh` valida esto en cada corrida: cualquier IP de `mac-*.txt` que caiga dentro de alguno de los dos rangos reservados aborta el reload con una línea `ERROR:` puntual y una notificación de escritorio — ver [uleases](#uleases) más abajo para ejemplos — pero lo más seguro es mantener siempre las IPs de `mac-*.txt` fuera de ambos rangos desde el principio. |
| **Indefinite MAC rotation bypasses grace→block promotion** | **Rotación indefinida de MAC evade la promoción grace→block** | `ugrace.txt` classification is keyed exclusively by MAC address (see *MAC randomization* above). A client that presents a new MAC on each reconnection is treated as a brand-new client every time: it receives a fresh `BLOCKDHCP_GRACE_SECONDS` timer and never accumulates enough grace-period age to be promoted to `blockdhcp.txt`. `pydhcpd`'s own DHCP rate-limiting (keyed per-MAC) does not mitigate this — it throttles request volume from a single identity, not the number of distinct identities a client can present, so the pattern is unaffected by any per-MAC threshold. DHCP client-hostname (option 12) cannot serve as a secondary identity signal either: it is client-supplied, unauthenticated (trivially spoofable), and not always present in `pydhcpd.leases` to begin with. There is no way to correlate rotated MACs to the same physical device from `pydhcpd.leases` alone; that would require device fingerprinting at the AP/802.11 layer, outside the scope of a DHCP-lease-based tool. <br><br>**Impact is bounded by firewall scope, not eliminated**: the `macgrace` ipset only grants DNS resolution and captive-portal ports — the same access any new, first-time client already receives — so rotating a MAC indefinitely does not grant more network access than a single legitimate connection would, *provided* the `macgrace` DNS rule is restricted to the configured resolvers (`SERV_DNS`), as in the reference `uiptables_example.sh`. If that rule instead accepts DNS to any destination, grace-state clients gain an unrestricted DNS channel that can be used for DNS tunneling — combined with indefinite MAC rotation, this becomes a persistent internet bypass that never requires redeeming a voucher. The residual cost of MAC rotation even with the DNS rule restricted is operational, not a security bypass: `ugrace.txt`/`blockdhcp.txt` accumulate entries for MACs that are never reused, and each rotation consumes a DHCP pool lease. | La clasificación en `ugrace.txt` se basa exclusivamente en la dirección MAC (ver *Aleatorización de MAC* arriba). Un cliente que presenta una MAC nueva en cada reconexión es tratado como cliente completamente nuevo cada vez: recibe un temporizador `BLOCKDHCP_GRACE_SECONDS` fresco y nunca acumula suficiente antigüedad en gracia como para ser promovido a `blockdhcp.txt`. El propio rate-limiting DHCP de `pydhcpd` (por MAC) no mitiga esto — limita el volumen de solicitudes de una sola identidad, no la cantidad de identidades distintas que un cliente puede presentar, así que el patrón no se ve afectado por ningún umbral por-MAC. El hostname DHCP (opción 12) tampoco puede servir como señal secundaria de identidad: lo provee el cliente, no está autenticado (trivialmente falsificable), y ni siquiera está siempre presente en `pydhcpd.leases`. No hay forma de correlacionar MACs rotadas con el mismo dispositivo físico solo desde `pydhcpd.leases`; eso requeriría fingerprinting de dispositivo a nivel de AP/802.11, fuera del alcance de una herramienta basada en leases DHCP. <br><br>**El impacto está acotado por el alcance del firewall, no eliminado**: el ipset `macgrace` solo otorga resolución DNS y los puertos del portal cautivo — el mismo acceso que ya recibe cualquier cliente nuevo de primera vez — así que rotar la MAC indefinidamente no otorga más acceso de red del que ya tendría una sola conexión legítima, *siempre que* la regla DNS de `macgrace` esté restringida a los resolvers configurados (`SERV_DNS`), como en el `uiptables_example.sh` de referencia. Si esa regla en cambio acepta DNS a cualquier destino, los clientes en estado grace ganan un canal DNS sin restricción utilizable para DNS tunneling — combinado con rotación indefinida de MAC, esto se convierte en un bypass de internet persistente que nunca requiere canjear un voucher. El costo residual de la rotación de MAC incluso con la regla DNS restringida es operativo, no un bypass de seguridad: `ugrace.txt`/`blockdhcp.txt` acumulan entradas de MACs que nunca se reutilizan, y cada rotación consume un lease del pool DHCP. |

### MongoDB - UniFi Controller Database

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Both <code>unifi-os</code> and <code>classic</code> run MongoDB embedded (container, or subprocess of <code>unifi.service</code> on port 27117) — <code>classic</code>'s separate <code>mongod.service</code> unit ships <b>disabled by default</b>. The issue below can only occur if that instance is shared with another application.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Tanto <code>unifi-os</code> como <code>classic</code> corren MongoDB embebido (contenedor, o subproceso de <code>unifi.service</code> en el puerto 27117) — la unidad <code>mongod.service</code> separada de <code>classic</code> viene <b>deshabilitada por defecto</b>. El problema de abajo solo puede presentarse si esa instancia se comparte con otra aplicación.
    </td>
  </tr>
</table>

<table>
  <tr>
    <th width="50%" align="left">Issue / Fix</th>
    <th width="50%" align="left">Problema / Solución</th>
  </tr>
  <tr>
    <td valign="top">
      <b>Issue:</b> Clients cannot reach the captive portal — MongoDB logs (<code>sudo journalctl -u mongod -f</code>) show <code>code=dumped</code>, <code>status=6/ABRT</code>, <code>code=exited</code> or <code>status=14/n/a</code>: it cannot write to its data directory.
      <br><br>
      <b>Fix:</b><br>
      <code>systemctl stop mongod</code><br>
      <code>chown mongodb:mongodb /var/lib/mongodb/WiredTiger.turtle</code><br>
      <code>chown mongodb:mongodb /var/lib/mongodb/WiredTiger.wt</code><br>
      <code>chown -R mongodb:mongodb /var/lib/mongodb</code><br>
      <code>systemctl start mongod</code><br>
      Verify: <code>sudo systemctl status mongod</code>
    </td>
    <td valign="top">
      <b>Problema:</b> Los clientes no pueden acceder al portal cautivo — los logs de MongoDB (<code>sudo journalctl -u mongod -f</code>) muestran <code>code=dumped</code>, <code>status=6/ABRT</code>, <code>code=exited</code> o <code>status=14/n/a</code>: no puede escribir en su directorio de datos.
      <br><br>
      <b>Solución:</b><br>
      <code>systemctl stop mongod</code><br>
      <code>chown mongodb:mongodb /var/lib/mongodb/WiredTiger.turtle</code><br>
      <code>chown mongodb:mongodb /var/lib/mongodb/WiredTiger.wt</code><br>
      <code>chown -R mongodb:mongodb /var/lib/mongodb</code><br>
      <code>systemctl start mongod</code><br>
      Verificar: <code>sudo systemctl status mongod</code>
    </td>
  </tr>
</table>

## ⚠️ WARNING: Network Access

---

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      This project is designed to run locally and be accessed over a LAN. It is not recommended to expose it to the internet, as it lacks the hardening required for public-facing deployments.
      If you choose to publish it despite this warning, it is strongly recommended to do so through an on-demand tunnel rather than opening ports directly. This approach lets you start and stop public access at will, without permanently exposing your server.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Este proyecto está diseñado para ejecutarse localmente y ser accedido en red LAN. No se recomienda exponerlo a internet, ya que no cuenta con el endurecimiento necesario para despliegues públicos.
      Si decide publicarlo a pesar de esta advertencia, se recomienda hacerlo a través de un túnel bajo demanda en lugar de abrir puertos directamente. Este enfoque le permite iniciar y detener el acceso público a voluntad, sin exponer el servidor de forma permanente.
    </td>
  </tr>
</table>

**Optional tunnel:**
- [Cloudflare Tunnel with Zero Trust Recommended](https://raw.githubusercontent.com/maravento/vault/master/scripts/bash/cftunnel.sh)

## NOTICE

---

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <strong>This repository</strong>
      <ul>
        <li>May include third-party components.</li>
        <li>Does not accept Pull Requests. Changes must be proposed via Issues.</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <strong>Este repositorio</strong>
      <ul>
        <li>Puede incluir componentes de terceros.</li>
        <li>No acepta Pull Requests. Los cambios deben proponerse mediante Issues.</li>
      </ul>
    </td>
  </tr>
</table>

## SPONSOR THIS PROJECT

---

[![Image](https://raw.githubusercontent.com/maravento/winexternal/master/img/maravento-paypal.png)](https://paypal.me/maravento)

## PROJECT LICENSES

---

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      This project uses a dual-licensing model to balance software freedom with content protection:
    </td>
    <td style="width: 50%; vertical-align: top;">
      Este proyecto utiliza un modelo de licencia dual para equilibrar la libertad del software con la protección del contenido:
    </td>
  </tr>
</table>

| Content | Licensed Under |
|---|---|
|Scripts, Binaries, Infrastructure|[![GPL-3.0](https://img.shields.io/badge/Open_Core-GPLv3-blue.svg?style=for-the-badge&labelWidth=120&logoWidth=20)](https://www.gnu.org/licenses/gpl.txt)|
|RAG, Workers, Specialized Modules, Docs|[![CC](https://img.shields.io/badge/Core_Engine-CC_BY--NC--ND_4.0-lightgrey.svg?style=for-the-badge&labelWidth=120&logoWidth=20)](https://creativecommons.org/licenses/by-nc-nd/4.0/)|

## DISCLAIMER

---

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
