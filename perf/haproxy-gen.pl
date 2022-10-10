#!/usr/bin/env perl

use strict;

my $maxconn = $ENV{"MAXCONN"} || 0;
my $nbthread = $ENV{"NBTHREAD"} || 4;
my $var_lib_haproxy_dir = "/tmp/lib/haproxy";

my $public_port = 8080;
my $public_ssl_port = 8443;
my $unix_at = "unix@";

print "global
  maxconn $maxconn
  nbthread $nbthread

  # daemon
  ca-base /etc/ssl
  crt-base /etc/ssl
  # TODO: Check if we can get reload to be faster by saving server state.
  # server-state-file ${var_lib_haproxy_dir}/run/haproxy.state
  stats socket ${var_lib_haproxy_dir}/run/haproxy.sock mode 600 level admin expose-fd listeners
  stats timeout 2m

  # Increase the default request size to be comparable to modern cloud load balancers (ALB: 64kb), affects
  # total memory use when large numbers of connections are open.
  # In OCP 4.8, this value is adjustable via the IngressController API.
  # Cluster administrators are still encouraged to use the default values provided below.
  tune.maxrewrite 8192
  tune.bufsize 32768

  # Configure the TLS versions we support
  ssl-default-bind-options ssl-min-ver TLSv1.2

# The default cipher suite can be selected from the three sets recommended by https://wiki.mozilla.org/Security/Server_Side_TLS,
# or the user can provide one using the ROUTER_CIPHERS environment variable.
# By default when a cipher set is not provided, intermediate is used.
  # user provided list of ciphers (Colon separated list as seen above)
  # the env default is not used here since we can't get here with empty ROUTER_CIPHERS
  tune.ssl.default-dh-param 2048
  ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384

  ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256

defaults
  maxconn $maxconn

  # To configure custom default errors, you can either uncomment the
  # line below (server ... 127.0.0.1:8080) and point it to your custom
  # backend service or alternatively, you can send a custom 503 or 404 error.
  #
  # server openshift_backend 127.0.0.1:8080
  errorfile 503 ${var_lib_haproxy_dir}/conf/error-page-503.http
  errorfile 404 ${var_lib_haproxy_dir}/conf/error-page-404.http

  timeout connect 5s
  timeout client 30s
  timeout client-fin 1s
  timeout server 30s
  timeout server-fin 1s
  timeout http-request 10s
  timeout http-keep-alive 300s

  # Long timeout for WebSocket connections.
  timeout tunnel 1h



frontend public

  bind :${public_port}
  mode http
  tcp-request inspect-delay 5s
  tcp-request content accept if HTTP
  monitor-uri /_______internal_router_healthz

  # Strip off Proxy headers to prevent HTTpoxy (https://httpoxy.org/)
  http-request del-header Proxy

  # DNS labels are case insensitive (RFC 4343), we need to convert the hostname into lowercase
  # before matching, or any requests containing uppercase characters will never match.
  http-request set-header Host %[req.hdr(Host),lower]

  # check if we need to redirect/force using https.
  acl secure_redirect base,map_reg_int(${var_lib_haproxy_dir}/conf/os_route_http_redirect.map) -m bool
  redirect scheme https if secure_redirect

  use_backend %[base,map_reg(${var_lib_haproxy_dir}/conf/os_http_be.map)]

  default_backend openshift_default

# public ssl accepts all connections and isn't checking certificates yet certificates to use will be
# determined by the next backend in the chain which may be an app backend (passthrough termination) or a backend
# that terminates encryption in this router (edge)
frontend public_ssl

  bind :${public_ssl_port}
  tcp-request inspect-delay 5s
  tcp-request content accept if { req_ssl_hello_type 1 }

  # if the connection is SNI and the route is a passthrough don't use the termination backend, just use the tcp backend
  # for the SNI case, we also need to compare it in case-insensitive mode (by converting it to lowercase) as RFC 4343 says
  acl sni req.ssl_sni -m found
  acl sni_passthrough req.ssl_sni,lower,map_reg(${var_lib_haproxy_dir}/conf/os_sni_passthrough.map) -m found
  use_backend %[req.ssl_sni,lower,map_reg(${var_lib_haproxy_dir}/conf/os_tcp_be.map)] if sni sni_passthrough

  # if the route is SNI and NOT passthrough enter the termination flow
  use_backend be_sni if sni

  # non SNI requests should enter a default termination backend rather than the custom cert SNI backend since it
  # will not be able to match a cert to an SNI host
  default_backend be_no_sni

##########################################################################
# TLS SNI
#
# When using SNI we can terminate encryption with custom certificates.
# Certs will be stored in a directory and will be matched with the SNI host header
# which must exist in the CN of the certificate.  Certificates must be concatenated
# as a single file (handled by the plugin writer) per the haproxy documentation.
#
# Finally, check re-encryption settings and re-encrypt or just pass along the unencrypted
# traffic
##########################################################################
backend be_sni
  server fe_sni ${unix_at}${var_lib_haproxy_dir}/run/haproxy-sni.sock weight 1 send-proxy

frontend fe_sni
  # terminate ssl on edge
  bind ${unix_at}${var_lib_haproxy_dir}/run/haproxy-sni.sock ssl crt ${var_lib_haproxy_dir}/router/certs/default.pem crt-list ${var_lib_haproxy_dir}/conf/cert_config.map accept-proxy
  mode http

  # Strip off Proxy headers to prevent HTTpoxy (https://httpoxy.org/)
  http-request del-header Proxy

  # DNS labels are case insensitive (RFC 4343), we need to convert the hostname into lowercase
  # before matching, or any requests containing uppercase characters will never match.
  http-request set-header Host %[req.hdr(Host),lower]



  # map to backend
  # Search from most specific to general path (host case).
  # Note: If no match, haproxy uses the default_backend, no other
  #       use_backend directives below this will be processed.
  use_backend %[base,map_reg(${var_lib_haproxy_dir}/conf/os_edge_reencrypt_be.map)]

  default_backend openshift_default

##########################################################################
# END TLS SNI
##########################################################################

##########################################################################
# TLS NO SNI
#
# When we don't have SNI the only thing we can try to do is terminate the encryption
# using our wild card certificate.  Once that is complete we can either re-encrypt
# the traffic or pass it on to the backends
##########################################################################
# backend for when sni does not exist, or ssl term needs to happen on the edge
backend be_no_sni
  server fe_no_sni ${unix_at}${var_lib_haproxy_dir}/run/haproxy-no-sni.sock weight 1 send-proxy

frontend fe_no_sni
  # terminate ssl on edge
  bind ${unix_at}${var_lib_haproxy_dir}/run/haproxy-no-sni.sock ssl crt ${var_lib_haproxy_dir}/router/certs/default.pem accept-proxy
  mode http

  # Strip off Proxy headers to prevent HTTpoxy (https://httpoxy.org/)
  http-request del-header Proxy

  # DNS labels are case insensitive (RFC 4343), we need to convert the hostname into lowercase
  # before matching, or any requests containing uppercase characters will never match.
  http-request set-header Host %[req.hdr(Host),lower]



  # map to backend
  # Search from most specific to general path (host case).
  # Note: If no match, haproxy uses the default_backend, no other
  #       use_backend directives below this will be processed.
  use_backend %[base,map_reg(${var_lib_haproxy_dir}/conf/os_edge_reencrypt_be.map)]

  default_backend openshift_default

##########################################################################
# END TLS NO SNI
##########################################################################

backend openshift_default
  mode http
  option forwardfor
  #option http-keep-alive
  option http-pretend-keepalive

##-------------- app level backends ----------------
";

