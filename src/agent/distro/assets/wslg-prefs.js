// wsl-bootstrap: system-wide default prefs for Firefox under WSLg.
// Installed to /usr/lib/firefox/defaults/pref/ (not owned by the package, so
// it survives upgrades) and applies to every profile.
//
// WSLg (Weston + RDP) cannot present hardware WebRender without see-through
// holes on translucent pages; software WebRender paints opaque frames.
// WebGL still runs on the GPU through Mesa D3D12.
pref("gfx.webrender.software", true);
pref("gfx.webrender.all", false);
pref("gfx.webrender.compositor", false);
pref("gfx.webrender.compositor.force-enabled", false);
pref("gfx.canvas.accelerated", false);
pref("layers.acceleration.force-enabled", false);
pref("gfx.x11-egl.force-enabled", false);
pref("widget.dmabuf.enabled", false);
pref("browser.tabs.inTitlebar", 0);

pref("webgl.disabled", false);
pref("webgl.force-enabled", true);
pref("webgl.enable-webgl2", true);
pref("media.hardware-video-decoding.enabled", false);
