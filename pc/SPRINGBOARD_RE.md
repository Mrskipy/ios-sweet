# Llegar a SpringBoard en PC: qué hay que reversear y qué sólo hay que escribir

Estado: 2026-10-21. Base: `kernel.development.sweet` (run `39713603840`) arranca en
QEMU/Windows hasta `*** SWEET userspace: init running as PID 1 ***` con root `md0`
(mockfs). Ver `pc/README.md` §9 y `pc/evidence/`.

---

## 1. La buena noticia: no hay que reverse-engineer la GPU

En el teléfono **SpringBoard se dibuja con la CPU** (`README.md`: "Rendering runs
entirely on the CPU; there is no GPU driver"). El camino es:

```
backboardd (userland) --swap--> AppleCLCD::swap() --vsync timer--> AppleCLCD::present()
        -> compone las IOSurface de cada capa en fPixels (RAM 0x9c000000)
        -> reloj de panel (en QEMU: no existe, sobra)
```

`xnu/patches/0056-sweet-fb-throttled-present.patch` lo confirma: `present()` copia
las capas a memoria de panel, sin escalado; `sweetfb_hz` limita a 10 Hz porque 10 MB
por swap a 60 Hz se comía la CPU. En QEMU `0x9c000000` es RAM del `virt` y
`qemu-sweet.py` la vuelca por QMP: **los píxeles de SpringBoard saldrían en `fb.png`
sin emular ningún panel**.

Corolario: **no hace falta QuartzCore parcheado** (a diferencia de eShard/Inferno,
que sí tenían GPU/Metal que suplantar). Lo que hay que resolver es *de dónde lee
backboardd* y *cómo le llega el toque*.

## 2. La mala noticia: el root actual no es un root

El `md0` de hoy es **mockfs**: presenta el RAM disk como un sistema con un solo
`/sbin/launchd`. Sirve para probar el kernel, no para launchd/dyld/SpringBoard.
Para el userland real hace falta un HFS+ de ~12 GB montado como `/`.

Y no vale el truco de meterlo en el payload (`--ramdisk`): el payload, la RAM del
invitado y el fichero del host crecen los tres a 12-16 GB, y XNU tiene topes de
tamaño en el camino `md`/`memdev` (MaliosDark documenta el truncado de tamaño de
`md`, síntoma clásico del límite de 32 bits). Mal camino.

## 3. Los cuatro muros, en orden

### M1 — Root real: driver `virtio-blk` (escribir, no reversear)

- Qué: dispositivo de bloque MMIO de `virt`, cola virtqueue, lecturas/escrituras
  síncronas, `IOBlockStorageDevice` + `BSD` disk en XNU.
- Modelo a copiar: `xnu/patches/0028-sweet-ufs-root-device.patch` (ya implementa un
  host de bloque real con PRDT/bounce y se expone como `/dev/ufsroot0`).
- Coste: ~700-1200 líneas + 3-6 iteraciones de CI (8-10 min cada una).
- Ventaja: el HFS+ de 12 GB pasa a ser **un fichero en el PC**, no parte del payload;
  y sirve también para un root propio pequeño para probar sin IPSW.
- Criterio de aceptación: `-device virtio-blk-device` con un `.img` de 64 MB →
  `BSD root: vd0` → `hfs: mounted` (con un HFS+ de prueba) → `load_init_program`.

### M2 — Entrada: toque sin I²C

El teléfono inyecta toques con `sweet_hid_touch(finger, down, x, y)` (patch 0058) y
los botones con `sweet_hid_key()`; Goodix sobre GENI I²C no existe en QEMU.

- Opción barata (sin QEMU nuevo): boot-arg/`sysctl` que dispare secuencias HID
  (ya existe `sweethidtest=N` para Home). Suficiente para desbloquear y abrir apps.
- Opción buena: dispositivo MMIO de 32 bytes en QEMU que llame a `sweet_hid_touch()`
  desde el kernel, con gestos con `kIOHIDDigitizerEventFromEdgeTip` (patch 0071:
  sin eso, el gesto de home no funciona).
- Coste: 300-600 líneas. **No requiere RE de iOS.**

### M3 — Userland: reutilizar las recetas del teléfono

Todo esto ya está resuelto en `tools/sweet-root-tweaks.py` + NOTES (2026-10-18) y se
aplica al root:
- saltar Setup (`com.apple.purplebuddy.plist`: SetupDone/SetupFinishedAllSteps/SetupVersion 11),
- activación nativa Hactivation (ADT ya lo hace) y `systembag.kb` en `/private/var/keybags`,
- quitar CommCenter del `launchd.plist` (sin baseband),
- `BKNoWatchdogs` + `FBLaunchWatchdogExceptions` (TCG es lento: los watchdogs matarán
  apps si no se exceptúan),
- AppleKeyStore/WDT/AMFI/Sandbox: stubs del kernel, ya funcionan en QEMU (visto hoy).

### M4 — Rendimiento

TCG + render por CPU + 6-8 cores simulados: espera arranque de decenas de minutos y
1-5 fps. Ajustes: `cpus=1` (el ADT de QEMU ya es monoprocesador), `sweetfb_hz=2`,
`wdt=-1`, y no usar `-d int` en pasadas largas.

## 4. Dónde sí hay ingeniería inversa de verdad

Sólo si algo del userland exige hardware que no podemos falsear con lo que ya hay:

1. **Frameworks que consultan hardware concreto** (QuartzCore/Metal, IOMobileFramebuffer
   details, backboardd's display pipeline). El teléfono ya demostró que el camino CPU
   basta; si en QEMU peta, el trabajo es: extraer el dyld shared cache del IPSW
   (`dsc_extractor` / `ipsw`), desensamblar el frame concreto, y stubear la consulta.
2. **SEP / AppleKeyStore**: el stub devuelve éxito y "no passcode, unlocked" (visto en
   el boot de hoy). Sólo hay que reversear si un daemon pide una operación concreta
   cuya respuesta no basta con cero/éxito.
3. **Baseband / CommCenter**: no se reversea, se elimina del launchd.plist (como en el
   teléfono).
4. **Comprobaciones de plataforma** (MobileGestalt): ya resueltas por el ADT
   (iPhone10,3 / D22AP / `/buttons home-button-type 2`).

Herramientas: `ipsw` (blacktop), `jtool2`, `llvm-objdump`, y los símbolos del kernel
que ya tenemos (`llvm-nm kernel.development.sweet`).

## 5. Secuencia recomendada (sin IPSW primero, IPSW al final)

| # | Paso | Necesita IPSW | Salida verificable |
|---|---|---|---|
| 1 | `virtio-blk` + HFS+ pequeño de prueba | no | `BSD root: vd0`, mount, init |
| 2 | Inyección HID (boot-arg o MMIO) | no | swipe/click llega a `SweetHIDTouch` |
| 3 | `sweet-root-tweaks.py` sobre el root real | sí (12-16 GB, descifrado) | `launchd` + dyld cache |
| 4 | Primer `fb.png` con backboardd | sí | lock screen / SpringBoard |
| 5 | Rendimiento y gestos | sí | home screen usable |

Paso 3 es el que no se puede hacer sin ti: el IPSW de iPhone X 16.7.16 es de Apple,
está cifrado, y ni se redistribuye ni lo puedo descargar por ti. El resto sí.

## 6. Legal, en una línea

El IPSW y el root descifrado son de Apple: úsalo en tu equipo, no lo subas al repo
(`.gitignore` ya excluye `research/`). La emulación con fines de investigación tiene
cobertura en EE. UU. (Apple v. Corellium, 11th Cir. 2023), la redistribución no.

## 7. Referencias

- `xnu/patches/0056` (present por CPU), `0061` (1125x2436), `0028` (modelo de driver
  de bloque), `0021-0024` (mockfs/RAM disk), `0058/0060/0071` (HID/touch).
- `NOTES.md` 2026-10-18: qué plist/daemon hubo que tocar para ver SpringBoard en el
  teléfono.
- eShard (iOS 14 en QEMU, con parches de QuartzCore porque allí sí había Metal que
  suplantar): <https://eshard.com/posts/emulating-ios-14-with-qemu-part2>
- MaliosDark (iOS 27, límites de `md`, DCP/AGX):
  <https://github.com/MaliosDark/ios27-cl4-secure-world>
- `darwin-vm` (máquina `qemu-sptm`, A14+): <https://github.com/jprx/darwin-vm>
