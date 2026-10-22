# ios-sweet en un PC — port del arnés QEMU (Windows / Linux / macOS)

Este directorio es el **port a PC** de [ios-sweet](https://github.com/dipa-studio/ios-sweet):
el proyecto original mete el kernel XNU de Apple (xnu-8796, generación iOS 16) y el
userland real de iOS 16.7.16 del iPhone X dentro de un Redmi Note 10 Pro (`sweet`, SM7150).

Aquí no hay teléfono. Hay un PC, QEMU y el mismo kernel.

---

## 1. Veredicto corto

| Objetivo | ¿Se puede? | Por qué |
|---|---|---|
| **Nativo en PC (Windows x86-64)** | **No** | El kernel es ARM64 y sus drivers son del hardware del teléfono: UFS Qualcomm, panel AppleCLCD/IOMobileFramebuffer, PMIC/SPMI, I²C Goodix, PSCI por `smc`. En un x86 no hay nada de eso. |
| **Kernel SWEET real en QEMU (PC, Windows)** | **Sí** | Es lo que ya hace `tools/qemu-sweet.py`. Con el kernel compilado se llega a BSD init y, con un RAM disk, a ejecutar el primer proceso de usuario. |
| **GUI de iOS (SpringBoard) en QEMU** | **No con este repo** | Falta panel, disco, entrada y el root de iOS. Requiere drivers nuevos (virtio-blk / virtio-gpu / virtio-input), el IPSW de Apple (copyright, no redistribuible) y parchear QuartzCore para render por software. |
| **¿Existe algo que sí muestre iOS en un PC?** | **Sí, pero no es esto** | [Inferno (ChefKiss)](https://github.com/ChefKissInc/Inferno), fork de QEMU con `-M t8030`: iPhone 11 + iOS 14.x, llega a SpringBoard. No cubre iPhone X ni iOS 16.7.16. |

Resumen: **se puede arrancar el kernel de verdad en el PC; no se puede tener iOS de escritorio.**
Lo segundo no es configuración, es un proyecto de meses y con material de Apple que no se puede distribuir.

---

## 2. Qué contiene este port

```
pc/
  setup-pc.ps1        comprueba/instala QEMU, LLVM y Python (winget)
  selftest.ps1        autotest sin kernel de Apple: prueba toda la cadena
  selftest-kernel.S   "kernel" falso de 12 instrucciones (pinta el framebuffer)
  build-kernel.ps1    compila el kernel en GitHub Actions y baja el artefacto
  run-pc.ps1          arranca el kernel SWEET real en QEMU
  README.md           esto
```

Cambios en `tools/qemu-sweet.py` para que funcione fuera de Linux/macOS:

1. **QMP por TCP loopback** en vez de socket UNIX. Windows 11 sí tiene `AF_UNIX`,
   pero QEMU para Windows y el resto de herramientas no lo tratan igual; TCP es
   portable y no cambia la semántica (comandos HMP + `pmemsave`).
2. **QEMU se lanza con `cwd` = directorio de salida y rutas relativas.**
   Los `:` de `C:\...` rompen el parser de `-device loader,file=`, `-serial file:`
   y `-D`, porque QEMU separa opciones por `,` y prefijos por `:`.
3. Pistas de instalación para Windows (`winget`) en `--check-env`.

`mkadt.py`, `mkpayload.py` y `mkinit.py` son Python puro: funcionan tal cual.

---

## 3. Instalación (Windows)

```powershell
winget install SoftwareFreedomConservancy.QEMU
winget install LLVM.LLVM          # clang + llvm-nm
winget install GitHub.cli         # sólo para compilar el kernel en CI

pwsh -File pc/setup-pc.ps1 -Install
```

`setup-pc.ps1` verifica además que el modelo de CPU `cortex-a76` exista en QEMU
(es el que usa el proyecto para imitar los Kryo 470 Gold).

---

## 4. Paso 1 — comprobar que el arnés funciona (sin Apple, sin CI)

```powershell
pwsh -File pc/selftest.ps1
```

Compila un kernel falso, genera el ADT de QEMU, empaqueta un payload SWEETXNU real
(`mkpayload.py`), lo arranca con el mismo cargador que usa el kernel de verdad y
comprueba que el invitado escribió en el framebuffer (`0xff00ff00`) y que no hubo
excepciones de CPU.

Si esto pasa, todo el camino `mkadt → mkpayload → qemu-sweet → captura QMP`
está sano en tu PC. Si falla, el problema es el entorno, no XNU.

---

## 5. Paso 2 — compilar el kernel (necesita tu cuenta de GitHub)

XNU arm64 **no se compila en Windows**: el build real usa macOS + Xcode (`iig`,
cctools, el SDK) y el proyecto lo hace en un runner `macos-14`. La ruta práctica
es un fork y el workflow que ya existe:

```powershell
gh auth login
pwsh -File pc/build-kernel.ps1 -Fork
```

Hace fork, sube el árbol, lanza `.github/workflows/xnu.yml` (`MACHINE_CONFIG=SWEET`),
espera 5–15 min y deja el artefacto en `xnu/out/kernel.development.sweet`.
Los repos públicos tienen minutos macOS gratis.

> El kernel no está en git: es un artefacto de CI. Sin este paso `run-pc.ps1` no
> tiene nada que arrancar.

---

## 6. Paso 3 — arrancar el kernel en QEMU

```powershell
pwsh -File pc/run-pc.ps1 -Secs 240 -LiveSerial
```

Qué hace:

1. `mkadt.py --qemu` → ADT de Apple con GICD/GICR y CNTFRQ de QEMU `virt`
   (timer virtual INTID 27 en vez de 19; parche 0017 del proyecto).
2. `sweet-init.S` + `mkinit.py` → init estático arm64 firmado ad-hoc (sin IPSW).
3. `mkpayload.py` → payload `SWEETXNU` con el kernel, el init como RAM disk y
   `rd=md0`.
4. `qemu-sweet.py` → QEMU `virt,gic-version=3`, `cortex-a76`, 1 CPU, 4 GiB,
   coloca segmentos con `-device loader`, arranca en un stub de 6 instrucciones
   con `x0 = boot_args`, y al terminar vuelca el framebuffer por QMP.

Artefactos en `pc/out-run/run/`: `fb.png` (pantalla 1080×2400), `fb.txt` (texto
decodificado con `_iso_font` del kernel), `regs.txt`, `qemu.log`, `result.json`.

`--fail-on-panic` devuelve 2 si hay pánico visible y 3 si la pantalla no se puede
decodificar. **Ausencia de pánico no es arranque completo**: es una foto.

### Qué esperar (y cuánto tarda)

- QEMU en Windows es **TCG puro**: no hay KVM para ARM en Windows (WHPX sólo
  virtualiza x86). Aun así, medido en esta máquina: **`PID 1` aparece dentro de
  los primeros 45 s** de reloj real. Usa `-Secs 45` para fotografiar el log de
  arranque y `-Secs 600` si quieres ver el init acumulando latidos.
- Hitos razonables: mensajes del arnés → CPU/GIC/timer → pmap y memoria →
  `BSD initialization` → `load_init_program` → `SWEET userspace: init running as PID 1`.
- Si se queda en `Waiting on IOMedia` sin RAM disk, es normal: no hay root.

---

## 7. Lo que NO se puede (y qué haría falta)

| Falta | Consecuencia | Trabajo necesario |
|---|---|---|
| Panel (AppleCLCD / IOMobileFramebuffer) | Nada dibuja | Driver de display para QEMU (`virtio-gpu` o `ramfb`) + IOSurface compatible |
| UFS Qualcomm | No hay root | Driver `virtio-blk` en XNU + HFS+ (ya existe en el repo) |
| PMIC, I²C, SPMI | Sin táctil ni botones | `virtio-input` / `virtio-keyboard` |
| IPSW de iOS 16.7.16 | Sin SpringBoard ni apps | Descargarlo tú de Apple (copyright, no se puede distribuir) |
| QuartzCore + Metal | Sin compositor | Render por software parcheando CoreAnimation (lo que hace Inferno) |
| SEP / AppleKeyStore real | Seguridad desactivada | Stubs (el repo ya los tiene para el teléfono) |

O sea: el kernel es portable; el *userland* no es "instalar y ejecutar", es
reimplementar la capa de plataforma. Por eso el propio repo usa QEMU sólo como
regresión del kernel.

---

## 8. Alternativas si el objetivo es "ver iOS en un PC"

- **Inferno (ChefKiss)** — QEMU con `-M t8030`, iPhone 11, iOS 14.x, llega a
  SpringBoard con render por software. Necesita IPSW propio, ticket AP forjado,
  dump de SEP y una VM compañera. En Windows hay que usar `usb-conn-type=ipv4`
  porque no hay sockets UNIX. <https://chefkiss.dev/guides/inferno/>
- **eShard** — iOS 14 en QEMU hasta la home screen, con táctil y apps; su serie
  de artículos documenta cada muro (SEP, baseband, QuartzCore, multitouch).
  <https://eshard.com/posts/emulating-ios-14-with-qemu>
- **darwin-vm / qemu-sptm** — A14–A19 y M1–M5 hasta shell de root; corre en
  cualquier QEMU, pero el setup necesita un Mac. <https://github.com/jprx/darwin-vm>
- **MaliosDark** — iOS 27 con root APFS real, SpringBoard arranca >5 min pero
  **sin píxeles** todavía (falta DCP/AGX). Es la frontera actual.
  <https://github.com/MaliosDark/ios27-cl4-secure-world>
- **alephsecurity/xnu-qemu-arm64** — kernelcache de iOS 12.1 en QEMU 4.2
  parcheado con una machine type propia (`n66_iphone6splus`), sólo hasta bash.
  <https://alephsecurity.com/2019/06/17/xnu-qemu-arm64-1/>
- **PureDarwin 20.5** — XNU en x86-64 hasta escritorio gráfico: es Darwin, no iOS.
- **Corellium** — comercial, su propio hipervisor sobre ARM, sin host macOS.
- **El teléfono** — la única ruta documentada de *este* repo hasta la lock screen.

Orden de magnitud del trabajo que falta para SpringBoard en `virt` (estimación
del análisis de parches: ~81 parches, 1,48 MB de diff): driver de root
(virtio-blk ~1,5–2,5k líneas, XNU no tiene virtio), scanout en vivo (~100–300
líneas QEMU + IOSurface), entrada (~300–600 líneas), PSCI `hvc` vs `smc`
(~10–40), y luego el *userland*: IPSW propio, SEP/keystore, QuartzCore por
software. **Meses**, no configuración.

---

## 9. Evidencia de esta sesión (2026-10-21)

Máquina: Windows 11 x86-64, QEMU 11.1.0 (winget), LLVM 23.1.4, Python 3.12.

1. **QEMU ejecuta ARM64 en Windows (TCG).** Stub ensamblado a mano que escribe
   `OK` en la UART PL011 de `virt` con `-device loader` + `loader,addr=…,cpu-num=0`:
   salida `OK`. Confirma que el patrón de arranque que usa `qemu-sweet.py`
   (cargar segmentos planos y forzar el PC del CPU 0) funciona en Windows.
2. **Cadena completa del arnés.** `pwsh -File pc/selftest.ps1` →
   `[ok] el invitado escribio en el framebuffer (0xff00ff00)`,
   `[ok] sin excepciones de CPU`, `fb.png` de 1080×2400 con la banda verde de
   300 filas exacta. `regs.txt`: `PC=…b0000424 X00=…9c13c680 X01=…ff00ff00`.
   Es decir: `mkadt.py --qemu` → `mkpayload.py` → `qemu-sweet.py` → QMP
   (`stop`, `info registers`, `pmemsave`) → `fb.png` funcionan en Windows.
3. **Kernel SWEET real: arranca hasta userland.** Compilado en el fork
   (`Mrskipy/ios-sweet`, run `39713603840`, 8m14s) y descargado:
   `kernel.development.sweet` 17 206 064 B, SHA-256 `577f8b68…29ec3cc`.
   Arranque en QEMU en Windows (TCG, `cortex-a76`, 4 GiB, RAM disk `rd=md0`):

   ```
   Added memory device md0/rmd0 (01000000/12000000)
   BSD root: md0, major 1, minor 0
   load_init_program: attempting to load /sbin/launchd
   *** SWEET userspace: init running as PID 1 ***
   SWEET CPU: 1/1 CPUs initialized, SGI1 verified
   SWEET AKS: AppleKeyStore registered (no passcode, unlocked)
   SWEET WDT: IOWatchdog registered (accepts check-ins, never fires)
   SWEET HID: buttons/touch registered
   SWEET FB: AppleCLCD 1080x2400 stride 4320 at 0x9c000000, presented as 1125x2436
   Security policy loaded: SWEET built-in Mobile File Integrity (SWEET AMFI)
   DLIL: running SUM16 self-tests ... PASSED
   mbinit: done [64 MB total pool size, (42/21) split]
   ```

   `result.json`: `{"status": "no_panic_observed", "unknown_glyphs": 0}`.
   En la pasada de 600 s, 72 latidos de `SWEET init: still alive` (el init de
   prueba late cada 5 s): userland ejecutando syscalls y `select` de verdad.
   Capturas en `pc/evidence/`: `2026-10-21-qemu-windows-fb.txt` (texto de la
   pantalla decodificado del framebuffer) y `…-fb.png` (los 1080x2400 reales).

   Tiempo en TCG Windows: en una pasada de **45 s de reloj real** ya está
   `PID 1`; la pasada de 600 s acumuló 72 latidos (≈360 s de reloj de invitado).
   El cuello de botella no es la emulación: es que aquí no hay root de iOS.

Cambios necesarios para llegar aquí, y por qué:

| Síntoma en Windows | Causa | Arreglo |
|---|---|---|
| `qmp` no conecta | socket UNIX no portable | QMP por TCP loopback (`free_port()`) |
| QEMU no encuentra `ram.bin` / rompe rutas | `C:\` y `,` en `-device` | `cwd` = salida + nombres relativos |
| `mkpayload.py` AssertionError con un ejecutable de usuario | asumía `segs[0] == __TEXT` y no ignoraba `__PAGEZERO` | elegir `__TEXT` por nombre y saltar `__PAGEZERO` (el Mach-O de XNU no lo tiene: salida idéntica) |
| QEMU/MSI recién instalados "no existen" | PATH de la shell ya abierta | `find_qemu()` / `find_llvm_nm()` con rutas típicas de instalación |

---

## 10. Referencias

- Repo: <https://github.com/dipa-studio/ios-sweet>
- Arnés QEMU del proyecto: `tools/qemu-sweet.py`, `docs/QEMU_TESTING.md`
- Notas de ingeniería (incluye la sección "QEMU emulation"): `NOTES.md`
- Configs de máquina soportadas por XNU (no hay `VIRT`):
  <https://github.com/apple-oss-distributions/xnu/blob/main/makedefs/MakeInc.def>
- Toolchain de CI: <https://github.com/blacktop/darwin-xnu-build>
- QEMU `virt`: <https://www.qemu.org/docs/master/system/arm/virt.html>
- eShard, emular iOS 14 en QEMU:
  <https://eshard.com/posts/emulating-ios-14-with-qemu> ·
  <https://eshard.com/posts/emulating-ios-14-with-qemu-part2>
- Inferno / qemu-t8030: <https://github.com/ChefKissInc/Inferno> ·
  <https://github.com/TrungNguyen1909/qemu-t8030>
- alephsecurity (machine model iPhone 6s Plus):
  <https://github.com/alephsecurity/xnu-qemu-arm64>
- darwin-vm: <https://github.com/jprx/darwin-vm> ·
  MaliosDark: <https://github.com/MaliosDark/ios27-cl4-secure-world>
- Corellium: <https://support.corellium.com/environments/on-site>
