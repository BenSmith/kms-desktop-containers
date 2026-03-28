# GPU Acceleration in the KMS Desktop Container

A full account of getting hardware acceleration working for a Wayland desktop
container running inside a KVM VM, including what works, what doesn't, why,
and how we got there.

---

## Setup

- **Host machine**: AMD Ryzen 7 8745HS with Radeon 780M (integrated GPU)
- **Hypervisor**: libvirt/QEMU managed via virt-manager
- **Guest OS**: Fedora 43
- **Container**: rootless Podman, systemd PID 1, labwc compositor driving
  `/dev/dri/card0` directly via KMS/DRM

The container runs a full Wayland desktop (labwc + waybar + foot + Firefox +
PipeWire) without any host compositor. It gets device access via:
- `/dev/dri` — GPU (DRM/KMS)
- `/dev/input` — keyboard/mouse
- `/dev/snd` — ALSA audio
- `/run/seatd.sock` — DRM master and VT management (host seatd bind-mounted in)

---

## Baseline: The Problem

Out of the box with `WLR_RENDERER=gles2`, running `vblank_mode=0 glxgears`
inside the container showed **~130 FPS** while the same test on the bare host
showed **~24,000 FPS**.

The culprit was the virtio-gpu/virgl pipeline: every frame the compositor
renders using GLES2, it issues a `glFenceSync` + `glClientWaitSync` round-trip
through the virgl protocol to the host. This serializes each frame across the
virtio-gpu queue, creating a hard bottleneck regardless of how fast the
underlying GPU is.

---

## Step 1: Pixman Renderer — 27× Speedup

Setting `WLR_RENDERER=pixman` on the labwc compositor switches it from GPU
compositing (GLES2 via virgl) to **CPU compositing**. The compositor never
touches the GPU at all — it blits windows using the CPU and then does a single
DRM atomic commit.

Result: **~3,800 FPS** (compositor) / **~3,500 FPS** (glxgears via XWayland).

### Why this works

The virgl fence round-trip is the bottleneck, not CPU compositing speed. A
modern CPU can blit a 1280×800 desktop framebuffer in microseconds. Eliminating
the virgl fence entirely is faster than any amount of GPU-side optimization
within the virgl protocol.

### What it costs

The pixman renderer does not support importing client DMA-BUF textures. This
means:

| Client type | Works? | Why |
|---|---|---|
| XWayland apps (glxgears, Firefox in X mode) | ✅ | Xwayland falls back to `wl_shm` (CPU shared memory) |
| Native Wayland OpenGL apps | ✅ | EGL/virgl clients also use `wl_shm` fallback |
| Native Wayland Vulkan apps (vkcube, games) | ❌ | Render to DMA-BUF only; compositor can't import it |

In practice, for a desktop container running Firefox, terminals, and standard
apps, XWayland is fine and this limitation is irrelevant.

### Config

In the labwc systemd service:

```ini
Environment=WLR_RENDERER=pixman
Environment=WLR_DRM_NO_MODIFIERS=1
```

---

## Step 2: Venus Vulkan — Real GPU for Applications

virgl gives you OpenGL-over-virtio-gpu. Venus gives you **Vulkan-over-virtio-gpu**:
Vulkan API calls are forwarded from the guest driver to the host's actual Vulkan
implementation (RADV on AMD), which runs on the real GPU.

This matters for applications (games, WebGPU, GPU compute) that use Vulkan
directly, independent of which renderer labwc uses.

### What Venus requires

#### 1. blob resources + host-visible memory

The virtio-gpu device must be configured with blob resource support so that
guest Vulkan can share DMA-BUF memory with the host without copying:

In libvirt's `qemu:commandline` section:

```xml
<qemu:commandline>
  <qemu:arg value="-global"/>
  <qemu:arg value="virtio-gpu-gl-device.venus=true"/>
  <qemu:arg value="-global"/>
  <qemu:arg value="virtio-vga-gl.blob=true"/>
  <qemu:arg value="-global"/>
  <qemu:arg value="virtio-vga-gl.hostmem=256M"/>
</qemu:commandline>
```

And in the libvirt domain XML:

```xml
<memoryBacking>
  <source type='memfd'/>
  <access mode='shared'/>
</memoryBacking>
```

Verify in guest dmesg:
```
[drm] features: +virgl +edid +resource_blob +host_visible
[drm] number of cap sets: 3
[drm] cap set 0: id 1, max-version 1, max-size 308   ← must not time out
[drm] cap set 1: id 2, max-version 2, max-size 1384
[drm] cap set 2: id 4, max-version 0, max-size 160
```

Cap set 2 (id=4) is the Venus cap set. If cap set 0 times out, Venus is not
working.

#### 2. egl-headless display + SPICE without GL

The default SPICE GL configuration (`<graphics type='spice'><gl enable='yes'/>`)
creates an EGL context on the host that conflicts with the Venus render server's
EGL context. They both try to be the "primary" EGL client and one fails.

Fix: use `egl-headless` as the display device (pure render context, no SPICE
compositing) and a second plain SPICE device (no GL) for remote access:

```xml
<graphics type='egl-headless'/>
<graphics type='spice'>
  <listen type='none'/>
</graphics>
<video>
  <model type='virtio' heads='1' primary='yes'/>
</video>
```

In virt-manager, switch to the SPICE console (View → Consoles → SPICE) to see
the guest display. The egl-headless console can't be shown directly in
virt-manager.

#### 3. QEMU seccomp sandbox

By default, libvirt runs QEMU with `-sandbox on,...,spawn=deny,...`, which
prevents QEMU's virglrenderer from forking the `virgl_render_server` process
that Venus requires.

Symptom: cap set 0 times out in dmesg even with the correct qemu:commandline.

Fix: disable the seccomp sandbox in `/etc/libvirt/qemu.conf`:

```
seccomp_sandbox = 0
```

Then restart libvirtd (`sudo systemctl restart libvirtd`) and cold-boot the VM
(power off + start, not reboot — the QEMU process itself must restart).

> **Note**: Disabling the seccomp sandbox reduces the isolation of the QEMU
> process on the host. This is a trade-off: you get Vulkan acceleration in the
> guest at the cost of a weaker QEMU sandbox. On a personal workstation this is
> generally acceptable.

#### Alternative: pre-start the render server as a service

virglrenderer supports connecting to an already-running `virgl_render_server`
process via a Unix socket instead of forking one. If the render server is
started as a systemd service on the host *before* the VM boots, virglrenderer
connects to the socket rather than forking — `spawn=deny` is never triggered
and the sandbox can remain enabled.

The guest never interacts with the render server directly. The full path is:

```
guest kernel (virtio-gpu) → QEMU (virglrenderer) → virgl_render_server
```

The render server is purely a host-side concern. Check whether your distro
ships a ready-made unit:

```bash
rpm -ql virglrenderer | grep -E "service|socket"   # Fedora/RHEL
dpkg -L virglrenderer | grep -E "service|socket"   # Debian/Ubuntu
```

If not, it can be written as a socket-activated service pointing at
`/usr/libexec/virgl_render_server`. The socket path must match what
virglrenderer expects — this is not yet widely documented and may require
reading virglrenderer source or release notes for your version.

### Verifying Venus works

In the guest:

```bash
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.x86_64.json \
    vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName"
```

Expected output:
```
deviceName = Virtio-GPU Venus (AMD Radeon 780M Graphics (RADV PHOENIX))
driverName = venus
```

### What Venus gives you

Applications launched from inside the desktop (from a foot terminal, or via
autostart) can use Venus for Vulkan rendering. They get real AMD 780M GPU
acceleration — the same RADV driver as bare metal, proxied through virtio-gpu.

```bash
# From a foot terminal on the desktop:
vkcube --wsi wayland --c 300
```

---

## Step 3: `WLR_RENDERER=vulkan` — Attempted, Not Working

With Venus Vulkan available, the logical next step was to give the compositor
itself a Vulkan renderer. This would allow labwc to import client DMA-BUF
surfaces natively, making native Wayland Vulkan apps visible.

Setting `WLR_RENDERER=vulkan` in the labwc service causes labwc to crash
(SIGABRT, exit code 134) after ~100ms of startup. The crash happens inside
`wlroots`' Vulkan renderer at the point where it tries to import a GBM-allocated
DMA-BUF into a `VkImage` using `VK_EXT_image_drm_format_modifier`.

### Why it fails

wlroots' Vulkan renderer allocates a GBM buffer for the compositor's output
swapchain, then imports it into Vulkan via DMA-BUF. This import path requires
the Vulkan driver to create a `VkImage` with tiling derived from the DMA-BUF's
DRM format modifier.

Venus is a protocol-based Vulkan implementation — it serializes Vulkan calls
over the virtio-gpu protocol to the host. The DMA-BUF import path in Venus
(specifically, creating a `VkImage` from a GBM-allocated `LINEAR` DMA-BUF) does
not work correctly with the version of wlroots/mesa in Fedora 43. The Vulkan
driver aborts.

wlroots documents this itself:

```
[INFO] The vulkan renderer is only experimental and not expected to be ready
       for daily use
```

### Status and outlook

This crash is specific to wlroots' Vulkan renderer. Other compositors (KWin,
Mutter) have their own rendering stacks and may already handle the Venus
DMA-BUF import path correctly — if you were running KDE or GNOME in this
container instead of labwc, Vulkan compositing with Venus might work today.

wlroots explicitly labels its Vulkan renderer experimental and it is actively
developed. Venus is also still maturing. As both stabilize, this should work.
It is not a fundamental architectural impossibility — just two experimental
components that don't quite meet yet. Worth retesting on future Fedora releases.

| Renderer | Compositor FPS | Native Wayland Vulkan clients |
|---|---|---|
| `pixman` | ~3,800 | ❌ (DMA-BUF import not supported) |
| `gles2` | ~138 | ✅ (virgl EGL imports DMA-BUF) |
| `vulkan` | crashes | N/A |

The `gles2` renderer works with Vulkan clients because virgl's EGL implementation
handles DMA-BUF import through the standard `EGL_EXT_image_dma_buf_import`
path, which is stable. But the ~138 FPS limit from virgl fence round-trips
makes it unsuitable as the primary compositor renderer.

---

## Reverting Venus (Restoring the Seccomp Sandbox)

If you decide Venus isn't worth the seccomp trade-off (and with `WLR_RENDERER=pixman`
it isn't — no app actually benefits from it), you can cleanly remove it:

### 1. Re-enable the seccomp sandbox

In `/etc/libvirt/qemu.conf`, remove or comment out:

```
seccomp_sandbox = 0
```

Then restart libvirtd:

```bash
sudo systemctl restart libvirtd
```

### 2. Remove Venus from the libvirt XML

In virt-manager: Edit → Preferences → Enable XML editing, then edit the domain XML.

Remove from `qemu:commandline`:

```xml
<qemu:arg value="-global"/>
<qemu:arg value="virtio-gpu-gl-device.venus=true"/>
<qemu:arg value="-global"/>
<qemu:arg value="virtio-vga-gl.blob=true"/>
<qemu:arg value="-global"/>
<qemu:arg value="virtio-vga-gl.hostmem=256M"/>
```

Remove the memory backing block:

```xml
<memoryBacking>
  <source type='memfd'/>
  <access mode='shared'/>
</memoryBacking>
```

### 3. Simplify the display config

With pixman compositor you don't need GL on the host at all. Switch back to
plain SPICE (no egl-headless, no GL):

```xml
<graphics type='spice'>
  <listen type='none'/>
</graphics>
<video>
  <model type='virtio' heads='1' primary='yes'/>
</video>
```

### 4. Cold-boot the VM

Power off and start (not reboot) — the QEMU process must restart for seccomp
and display changes to take effect.

### What you lose

Nothing visible. With `WLR_RENDERER=pixman`:
- The compositor never uses the GPU
- Apps use virgl (OpenGL via virtio-gpu) for GPU acceleration — this is unaffected by Venus
- Native Wayland Vulkan clients can't be displayed regardless of whether Venus is present

---

## Summary: What Works

| Feature | Status | Notes |
|---|---|---|
| Desktop display | ✅ | labwc + pixman, ~3,800 FPS compositor |
| XWayland apps | ✅ | glxgears, Firefox (X mode), etc. |
| Firefox (Wayland) | ✅ | `MOZ_ENABLE_WAYLAND=1` set; uses wl_shm fallback |
| Audio (PipeWire) | ✅ | ALSA sink configured directly (udev bypass) |
| Venus Vulkan | ✅ | AMD 780M accessible in guest via `virtio_icd` |
| Vulkan apps (XWayland) | ✅ | Venus available to X11 apps via DISPLAY=:0 |
| Native Wayland Vulkan | ❌ | pixman compositor can't display DMA-BUF surfaces |
| Hardware video decode (VA-API) | ✅ (untested) | mesa-va-drivers installed |

## What Doesn't Work (and Why)

### Native Wayland Vulkan client display

`vkcube --wsi wayland` connects to labwc, renders frames using Venus (100% CPU
on the Venus dispatch thread), but no window appears. The frames are rendered
into DMA-BUF memory but the pixman compositor has no path to import and display
them. The process spins indefinitely.

This is a fundamental architecture constraint: **CPU compositor + GPU client
buffers don't mix**. To fix it you'd need either:
- `WLR_RENDERER=gles2` (accepts DMA-BUF import, but virgl fence overhead)
- `WLR_RENDERER=vulkan` (would be ideal, but crashes with Venus on Fedora 43)

### labwc Wayland socket visibility

The labwc Wayland socket (`/run/user/1000/wayland-0`) is created inside
labwc's private mount namespace (a consequence of systemd service isolation).
It's not visible to `podman exec` shells or processes outside the labwc service
tree. This is normal — apps launched from within the desktop (foot terminal,
autostart) are children of the service and inherit the namespace. Running
`WAYLAND_DISPLAY=wayland-0 someapp` directly from `podman exec` will fail with
"cannot connect to wayland".

---

## Key Bugs Encountered

### `amixer set Master 74` → silent

`amixer set` requires a numeric argument for Simple mixer controls. The correct
syntax is `amixer sset Master 74% unmute`. Using `set` instead of `sset` or
omitting the `%` sign silently does nothing.

### `WLR_RENDERER=vulkan` → "Could not match drm and vulkan device"

Before Venus was enabled, trying the Vulkan renderer failed because RADV
(the host AMD driver) doesn't match the guest's `/dev/dri/card0` (virtio_gpu).
RADV is for direct AMD hardware; Venus is the correct driver for virtio-gpu.

### Cap set 0 timeout despite correct qemu:commandline

The Venus cap set registered (3 cap sets shown in dmesg) but cap set 0 kept
timing out. The QEMU log revealed `-sandbox on,...,spawn=deny,...` — libvirt's
seccomp sandbox was blocking `virglrenderer` from forking the
`virgl_render_server` process. Venus requires that subprocess to handle
Vulkan command serialization. The fix was `seccomp_sandbox = 0` in
`/etc/libvirt/qemu.conf`.

### SPICE GL + Venus → blank display

With Venus enabled and `<gl enable='yes'/>` on the SPICE display, the VM
booted but the display went blank after a few seconds. The virgl initialization
log showed `virgl could not be initialized: -1`. Two EGL contexts (SPICE GL
renderer + Venus render server) were competing. Switching to `egl-headless`
for rendering and plain SPICE for display resolved this.

### podman-compose `x-podman` API change

podman-compose 1.5 changed the UID/GID mapping syntax. The old nested form:

```yaml
x-podman:
  uidmap:
    - "+1000:@1000:1"
```

was replaced with flat dotted keys:

```yaml
x-podman.uidmaps:
  - "+1000:@1000:1"
```

Using the old form produces: *"Configuration under x-podman has been migrated
to x-podman.uidmaps and x-podman.gidmaps fields."*

### rtkit-daemon → degraded systemd state

`rtkit-daemon` fails in user-namespaced containers because it can't access
`/proc/sys/kernel/sched_rt_*`. PipeWire requests RT priority through it and
falls back gracefully, but the failed unit leaves `systemctl is-system-running`
reporting `degraded`. Fix: mask the unit in the Containerfile:

```dockerfile
RUN ln -sf /dev/null /etc/systemd/system/rtkit-daemon.service
```

### `cp` as a Dockerfile instruction

A line of the form:

```dockerfile
cp /etc/gtk-3.0/settings.ini /etc/gtk-4.0/settings.ini
```

at the top level of a Containerfile is interpreted as a `COPY` instruction
(case-insensitive), not a shell command. Wrap it in `RUN`:

```dockerfile
RUN cp /etc/gtk-3.0/settings.ini /etc/gtk-4.0/settings.ini
```
