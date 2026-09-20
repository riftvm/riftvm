# What OpenGL the guest actually gets (2026-09-20)

Prompted by a Ghostty install failing with "Unable to acquire an OpenGL context
for rendering", and the reasonable question behind it: does RiftVM support
OpenGL at all?

It does. The guest gets **OpenGL ES 3.0** and **desktop OpenGL 2.1 compatibility**,
with no desktop core profile. Ghostty needs **OpenGL 4.3**, which this stack
cannot reach by any route tried here. The ceiling is ANGLE's Metal backend, not
anything in RiftVM's code.

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

**Ghostty is not**, and its own log says exactly why. Installed from the
`omarchy` repo and run on a `.16` machine, it reproduces the reported error, and
with a Mesa version override it gets one step further and states its
requirement:

```
info(opengl): loaded OpenGL 3.3
warning(opengl): OpenGL version is too old. Ghostty requires OpenGL 4.3
```

**It needs 4.3, not 3.3.** Claiming 4.3 as well gets past the version check and
fails at the first shader link, because the features behind the number are not
there:

```
error(opengl): program link failure — Too many fragment shader storage blocks (1/0)
```

Shader storage buffers: zero available. A direct probe agrees — a 4.3 core
context can be *created* under the override, but `glCreateShader(GL_COMPUTE_SHADER)`
returns nothing, so there is no compute support to build on.

The general rule: applications written against GLES, or against desktop GL 2.1,
work. Applications that require desktop GL core do not, and an override cannot
supply what the driver does not implement.

## Could Ghostty ever work?

Not without a different host GL. Even macOS's own deprecated OpenGL framework
stops at 4.1 core, below the 4.3 Ghostty asks for, and adopting it would give up
the ANGLE/Metal zero-copy presentation path the whole renderer is built on. The
honest answer is that Ghostty is out of reach here, and `foot` — the image's own
terminal — is what to use.

## What is worth revisiting

Mesa reports desktop GL 2.1 conservatively because the host is GLES; under an
override the same driver will hand out a working GL 3.3 core context and compile
a `#version 330 core` shader. So the *reported* ceiling is lower than the real
one, and an application needing 3.3 rather than 4.3 might well run. That is an
observation, not a recommendation: an override makes Mesa claim features it may
not have, which is precisely how the 4.3 attempt failed.

## Not claimed

No attempt was made to patch virglrenderer's capability reporting. Whether a
newer ANGLE would offer GLES 3.1 on Metal was not tested — only the runtime
RiftVM currently bundles. No application other than Ghostty and Nautilus was
exercised. This records a limit rather than fixing one.
