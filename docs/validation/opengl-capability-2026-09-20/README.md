# What OpenGL the guest actually gets (2026-09-20)

Prompted by a Ghostty install failing with "Unable to acquire an OpenGL context
for rendering", and the reasonable question behind it: does RiftVM support
OpenGL at all?

It does. The guest gets **OpenGL ES 3.0** and **desktop OpenGL 2.1 compatibility**.
What it does not get is a desktop **core** profile, and that is what Ghostty
needs. The ceiling is ANGLE's Metal backend, not anything in RiftVM's code.

## What the guest reports

From `eglinfo -B` on a `.15` machine, identical across the GBM, Wayland and X11
platforms:

```
OpenGL compatibility profile renderer: virgl
OpenGL compatibility profile version:  2.1 Mesa 26.2.3-arch1.1
OpenGL compatibility profile shading language version: 1.20
OpenGL ES profile version:             OpenGL ES 3.0 Mesa 26.2.3-arch1.1
OpenGL ES profile shading language version: OpenGL ES GLSL ES 3.00
```

and from `glxinfo -B`:

```
Accelerated: yes
Max core profile version:  0.0
Max compat profile version: 2.1
Max GLES[23] profile version: 3.0
```

`Accelerated: yes` with `Max core profile version: 0.0` is the whole story in
two lines: acceleration works, a core profile does not exist.

## Why

virglrenderer can only offer the guest what its host context has. RiftVM's host
context is ANGLE on Metal, which is a **GLES** implementation — there is no
desktop GL underneath it to expose, so Mesa's virgl driver reports desktop GL at
the 2.1 compatibility level and puts the real capability in the GLES profile.

The obvious lever is to ask ANGLE for more. RiftVM requests
`EGL_CONTEXT_CLIENT_VERSION 3`, so a natural question is whether 3.1 or 3.2
would raise the guest's ceiling. Probed directly against the bundled runtime:

```
EGL 1.5  vendor=Google Inc. (Apple)   (ANGLE 2.1.1 git hash: 2d91f554ab55)
  request GLES 3.0 -> GL_VERSION="OpenGL ES 3.0 (ANGLE …)"
  request GLES 3.1 -> FAILED (EGL_BAD_MATCH 0x3009)
  request GLES 3.2 -> FAILED (EGL_BAD_MATCH 0x3009)
  request GLES 2.0 -> GL_VERSION="OpenGL ES 3.0 (ANGLE …)"
```

ANGLE's Metal backend tops out at GLES 3.0, so there is no headroom to ask for.
Asking for 2.0 already yields a 3.0 context, which is why the current code gets
everything available.

## What this breaks, and what it does not

**GTK4 applications are fine.** Nautilus — GTK4, already in the image — launches
and maps its window normally, because GTK4's renderer runs on GLES. Every GSK
renderer (`ngl`, `gl`, `vulkan`, `cairo`) starts.

**Ghostty is not.** It wants a desktop GL core profile, and `Max core profile
version: 0.0` means it cannot have one, so GTK reports it cannot acquire a
context. Ghostty is not part of the image in any case — the image's terminal is
`foot` — so this affects a separately installed copy.

The general rule: applications written against GLES, or against desktop GL 2.1,
work. Applications that require desktop GL 3.2 core or later do not.

## Not claimed

No attempt was made to patch virglrenderer's capability reporting, and no other
application was surveyed for a core-profile requirement. Whether a newer ANGLE
would offer GLES 3.1 on Metal was not tested — only the runtime RiftVM currently
bundles. Nothing here changes with the RiftVM release that accompanies it; this
records a limit rather than fixing one.
