-- Prosody only carries federation for the push component. It has no users, and
-- accepts no client connections.
local push_domain = Lua.os.getenv("PUSH_DOMAIN")

pidfile = "/var/run/prosody/prosody.pid"
log = { info = "*console" }

certificates = "/etc/prosody/certs"

modules_disabled = { "c2s", "offline", "register" }
modules_enabled = { "tls", "dialback", "ping" }
allow_registration = false

s2s_ports = { 5269 }
s2s_secure_auth = true
c2s_direct_tls_ports = {}
s2s_direct_tls_ports = {}
http_ports = {}
https_ports = {}

-- Reachable only inside the Docker network: the port isn't published.
component_ports = { 5347 }
component_interfaces = { "*" }

-- Prosody refuses to start without a host. Nothing can log in to this one, since
-- client connections are disabled and it has no users.
VirtualHost "localhost"

Component (push_domain)
    component_secret = Lua.os.getenv("COMPONENT_SECRET")
