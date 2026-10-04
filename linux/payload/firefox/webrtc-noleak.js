// wsl-bootstrap (optional): WebRTC only offers the default route's address,
// never LAN/host candidates. With the egress tunnel that address is the exit IP.
pref("media.peerconnection.ice.default_address_only", true);
pref("media.peerconnection.ice.no_host", true);
