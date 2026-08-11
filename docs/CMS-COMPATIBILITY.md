<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# CMS Compatibility Guide
# WordPress, Drupal, Moodle, and More

## Overview

http-capability-gateway is designed to be a **good citizen** in existing web infrastructure. It plays nicely with popular CMSs, doesn't break admin panels, and respects standard web patterns.

---

## 🎯 Design Principles

1. **Preserve, Don't Replace** - Keep existing headers, cookies, sessions
2. **Bypass When Needed** - Admin paths shouldn't need verb governance
3. **Auto-Detect** - Recognize CMS patterns automatically
4. **Document Everything** - Clear examples for each CMS
5. **No Surprises** - Predictable behavior in proxy chains

---

## 🔧 WordPress Compatibility

### Auto-Detection
HCG automatically detects WordPress by:
- `X-Powered-By: PHP` + presence of `/wp-admin/`
- WordPress cookies (`wordpress_*`, `wp-settings-*`)
- REST API at `/wp-json/`

### Preserved Headers
```yaml
# Automatically preserved for WordPress
headers:
  - X-WordPress-Nonce
  - X-WP-Total
  - X-WP-TotalPages
  - Link (REST API pagination)
```

### Preserved Cookies
```yaml
cookies:
  - wordpress_*          # WordPress auth cookies
  - wp-settings-*        # User settings
  - wordpress_test_cookie
  - wordpress_logged_in_*
  - wp_woocommerce_*     # WooCommerce
```

### Recommended Policy

```yaml
# wordpress-policy.yaml
dsl_version: "1"

governance:
  global_verbs:
    - GET
    - POST
    - HEAD
    - OPTIONS

  routes:
    # Admin panel - bypass governance for authenticated users
    - path: "/wp-admin/.*"
      verbs: [GET, POST, PUT, DELETE, PATCH]
      bypass_if_cookie: "wordpress_logged_in_"

    # AJAX endpoint
    - path: "/wp-admin/admin-ajax.php"
      verbs: [GET, POST]

    # REST API
    - path: "/wp-json/.*"
      verbs: [GET, POST, PUT, DELETE, PATCH, OPTIONS]

    # XML-RPC (if needed, consider disabling)
    - path: "/xmlrpc.php"
      verbs: [POST]
      rate_limit: 10/min  # Prevent brute force

    # Login page
    - path: "/wp-login.php"
      verbs: [GET, POST]
      rate_limit: 5/min   # Prevent brute force

stealth:
  enabled: true
  status_code: 404
```

### WooCommerce Support
```yaml
routes:
  # Checkout flow
  - path: "/checkout/.*"
    verbs: [GET, POST]

  # Cart AJAX
  - path: "/\\?wc-ajax=.*"
    verbs: [GET, POST]

  # Payment gateway callbacks
  - path: "/wc-api/.*"
    verbs: [GET, POST, PUT]
```

### Multisite Configuration
```yaml
routes:
  # Network admin
  - path: "/wp-admin/network/.*"
    verbs: [GET, POST, PUT, DELETE]
    bypass_if_cookie: "wordpress_logged_in_"
```

---

## 🎨 Drupal Compatibility

### Auto-Detection
HCG detects Drupal by:
- `X-Generator: Drupal`
- Cache tags: `X-Drupal-Cache-Tags`
- Session cookies: `SESS*`

### Preserved Headers
```yaml
headers:
  - X-Drupal-Cache
  - X-Drupal-Cache-Tags
  - X-Drupal-Cache-Contexts
  - X-Drupal-Cache-Max-Age
  - X-Generator
  - X-Drupal-Dynamic-Cache
```

### Preserved Cookies
```yaml
cookies:
  - SESS*                # Drupal session
  - SSESS*               # Secure session
  - Drupal.visitor.*     # Visitor tracking
```

### Recommended Policy

```yaml
# drupal-policy.yaml
dsl_version: "1"

governance:
  global_verbs:
    - GET
    - HEAD
    - OPTIONS

  routes:
    # Admin paths
    - path: "/admin/.*"
      verbs: [GET, POST, PUT, DELETE, PATCH]
      bypass_if_cookie: "SESS"

    # User paths
    - path: "/user/.*"
      verbs: [GET, POST, PUT, DELETE]

    # Batch processing
    - path: "/batch"
      verbs: [GET, POST]

    # AJAX callbacks
    - path: "/system/ajax"
      verbs: [POST]

    # REST API
    - path: "/api/.*"
      verbs: [GET, POST, PUT, DELETE, PATCH, OPTIONS]

    # JSON:API
    - path: "/jsonapi/.*"
      verbs: [GET, POST, PATCH, DELETE, OPTIONS]

stealth:
  enabled: true
  status_code: 404
```

### Drupal Cache Integration
```yaml
# Work with Drupal's cache system
caching:
  respect_backend_headers: true
  respect_cache_tags: true
  invalidate_on_tags:
    - "node:*"
    - "taxonomy_term:*"
```

---

## 📚 Moodle Compatibility

### Auto-Detection
- Session cookies: `MoodleSession*`
- Admin path: `/admin/`
- Login page: `/login/index.php`

### Preserved Headers
```yaml
headers:
  - X-Moodle-Version
  - X-Frame-Options  # Moodle sets this for embedding
```

### Preserved Cookies
```yaml
cookies:
  - MoodleSession*
  - MOODLEID_*
  - moodle_test_cookie
```

### Recommended Policy

```yaml
# moodle-policy.yaml
dsl_version: "1"

governance:
  global_verbs:
    - GET
    - POST
    - HEAD

  routes:
    # Admin panel
    - path: "/admin/.*"
      verbs: [GET, POST, PUT, DELETE]
      bypass_if_cookie: "MoodleSession"

    # Course editing
    - path: "/course/.*"
      verbs: [GET, POST, PUT, DELETE]

    # File uploads
    - path: "/repository/.*"
      verbs: [GET, POST]
      max_body_size: 100MB

    # Quiz attempts
    - path: "/mod/quiz/.*"
      verbs: [GET, POST]

    # AJAX endpoints
    - path: "/lib/ajax/.*"
      verbs: [POST]

stealth:
  enabled: true
  status_code: 404
```

---

## 🌐 Reverse Proxy Integration

### Common Proxy Setups

#### 1. CloudFlare → HCG → Backend
```yaml
# Preserve CloudFlare headers
proxy:
  preserve_headers:
    - CF-Connecting-IP
    - CF-Ray
    - CF-Visitor
    - CF-IPCountry
    - CF-Cache-Status

  # Trust CloudFlare IPs for X-Forwarded-For
  trusted_proxies:
    - 173.245.48.0/20
    - 103.21.244.0/22
    # ... (CloudFlare IP ranges)
```

#### 2. nginx → HCG → Backend
```nginx
# /etc/nginx/sites-available/mysite
upstream hcg {
    server 127.0.0.1:4000;
    keepalive 32;
}

server {
    listen 80;
    server_name example.com;

    location / {
        proxy_pass http://hcg;

        # Important: Preserve these
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Request-ID $request_id;

        # HTTP/1.1 for keepalive
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
```

#### 3. Apache → HCG → Backend
```apache
# /etc/apache2/sites-available/mysite.conf
<VirtualHost *:80>
    ServerName example.com

    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:4000/
    ProxyPassReverse / http://127.0.0.1:4000/

    # Preserve headers
    RequestHeader set X-Forwarded-Proto "http"
    RequestHeader set X-Forwarded-Port "80"
</VirtualHost>
```

#### 4. Caddy → HCG → Backend
```caddyfile
# Caddyfile
example.com {
    reverse_proxy localhost:4000 {
        header_up X-Real-IP {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

#### 5. Varnish → HCG → Backend
```vcl
# /etc/varnish/default.vcl
backend hcg {
    .host = "127.0.0.1";
    .port = "4000";
}

sub vcl_recv {
    # Set backend
    set req.backend_hint = hcg;

    # Preserve headers
    set req.http.X-Forwarded-For = client.ip;

    # Allow purging from localhost
    if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            return (synth(405, "Not allowed"));
        }
        return (purge);
    }
}
```

---

## 🔒 .well-known/ Support

### Automatic Passthrough

HCG **automatically bypasses policy** for `.well-known/*` paths:

```yaml
# Built-in, no configuration needed
well_known:
  auto_passthrough: true
  paths:
    - /.well-known/acme-challenge/*    # Let's Encrypt
    - /.well-known/security.txt        # Security contact
    - /.well-known/change-password     # Password managers
    - /.well-known/openid-configuration # OAuth/OIDC
    - /.well-known/webfinger           # Federation
    - /.well-known/nodeinfo            # Fediverse
    - /.well-known/host-meta          # Discovery
```

### ACME / Let's Encrypt Integration

**Setup 1: Certbot with HCG**
```bash
# HCG automatically serves ACME challenges
certbot certonly --webroot \
  -w /var/www/html \
  -d example.com \
  --pre-hook "systemctl stop hcg" \
  --post-hook "systemctl start hcg"

# Or use standalone mode (HCG on different port)
certbot certonly --standalone \
  --preferred-challenges http \
  -d example.com
```

**Setup 2: ACME challenges through HCG**
```yaml
# config/prod.exs
config :http_capability_gateway,
  acme_challenge_dir: "/var/lib/acme/challenges"
```

HCG will serve files from this directory at `/.well-known/acme-challenge/`

### Security.txt

```yaml
# Expose security policy through HCG
# Place file at: priv/static/.well-known/security.txt
# HCG serves it automatically
```

Example `/var/www/html/.well-known/security.txt`:
```
Contact: mailto:security@example.com
Expires: 2027-12-31T23:59:59z
Encryption: https://example.com/pgp-key.txt
Preferred-Languages: en
Canonical: https://example.com/.well-known/security.txt
```

---

## 🛡️ Security Headers

### Preserve Backend Headers

```yaml
# HCG preserves these by default
security_headers:
  preserve_from_backend:
    - Content-Security-Policy
    - Content-Security-Policy-Report-Only
    - Strict-Transport-Security
    - X-Frame-Options
    - X-Content-Type-Options
    - X-XSS-Protection
    - Referrer-Policy
    - Permissions-Policy
    - Cross-Origin-Embedder-Policy
    - Cross-Origin-Opener-Policy
    - Cross-Origin-Resource-Policy
```

### Add Missing Headers

```yaml
# config/prod.exs
config :http_capability_gateway,
  security_headers:
    add_if_missing: true
    defaults:
      "X-Frame-Options": "SAMEORIGIN"
      "X-Content-Type-Options": "nosniff"
      "Referrer-Policy": "strict-origin-when-cross-origin"
      "Permissions-Policy": "geolocation=(), microphone=(), camera=()"
```

### Header Merging Strategy

**Precedence** (highest to lowest):
1. Backend headers (always preserved)
2. Policy-defined headers
3. Gateway default headers

**Example:**
```yaml
routes:
  - path: "/embed/.*"
    headers:
      set:
        X-Frame-Options: "ALLOW-FROM https://trusted.com"
      # This overrides default SAMEORIGIN
```

---

## 🌍 CORS Support

### Preserve CORS Headers

```yaml
# Automatically preserved
cors_headers:
  - Access-Control-Allow-Origin
  - Access-Control-Allow-Methods
  - Access-Control-Allow-Headers
  - Access-Control-Expose-Headers
  - Access-Control-Max-Age
  - Access-Control-Allow-Credentials
```

### OPTIONS Preflight

```yaml
# Auto-handle OPTIONS for CORS
governance:
  global_verbs:
    - OPTIONS  # Always allow preflight

routes:
  - path: "/api/.*"
    verbs: [GET, POST, PUT, DELETE, OPTIONS]
    cors:
      enabled: true
      allow_origin: "https://app.example.com"
      allow_credentials: true
```

---

## 📝 Resource Hints

### Preserve Link Headers

```yaml
# Preserve resource hints from backend
resource_hints:
  preserve:
    - Link  # For preload, prefetch, dns-prefetch
```

**Example backend response:**
```
Link: </style.css>; rel=preload; as=style
Link: </script.js>; rel=preload; as=script
Link: <https://cdn.example.com>; rel=dns-prefetch
```

HCG passes these through unchanged.

---

## 🧪 Testing CMS Compatibility

### WordPress Health Check
```bash
# Test admin access
curl -I https://example.com/wp-admin/
# Should redirect to login or show 200 if logged in

# Test REST API
curl https://example.com/wp-json/wp/v2/posts
# Should return JSON

# Test AJAX
curl -X POST https://example.com/wp-admin/admin-ajax.php \
  -d "action=heartbeat"
```

### Drupal Health Check
```bash
# Test admin access
curl -I https://example.com/admin
# Should redirect to login or show 200 if logged in

# Test JSON:API
curl https://example.com/jsonapi/node/article
# Should return JSON:API response

# Test status page
curl https://example.com/admin/reports/status
```

### Moodle Health Check
```bash
# Test login page
curl -I https://example.com/login/index.php
# Should show 200

# Test admin
curl -I https://example.com/admin/
# Should redirect to login or show 200 if logged in
```

---

## 🐛 Troubleshooting

### Problem: Admin Panel Broken
**Symptoms**: Can't access /wp-admin/, getting 404
**Solution**: Add bypass rule for admin paths
```yaml
routes:
  - path: "/wp-admin/.*"
    verbs: [GET, POST, PUT, DELETE, PATCH]
    bypass_if_authenticated: true
```

### Problem: AJAX Requests Failing
**Symptoms**: Admin-ajax.php returns 404
**Solution**: Ensure POST is allowed
```yaml
routes:
  - path: "/wp-admin/admin-ajax.php"
    verbs: [POST]
```

### Problem: Sessions Not Persisting
**Symptoms**: Keep getting logged out
**Solution**: Check cookie preservation
```bash
# Verify cookies are passed through
curl -v -b "wordpress_logged_in_xxx=..." \
  https://example.com/wp-admin/
```

### Problem: Cache Headers Ignored
**Symptoms**: Pages not caching
**Solution**: Enable cache header respect
```yaml
caching:
  respect_backend_headers: true
```

---

## 📚 Complete Examples

### WordPress + nginx + Let's Encrypt
```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # ACME challenges bypass HCG
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Everything else goes through HCG
    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Drupal + Varnish + HCG
```vcl
# Varnish caches, HCG enforces policy
sub vcl_recv {
    # Bypass cache for admin
    if (req.url ~ "^/admin" || req.url ~ "^/user") {
        return (pass);
    }

    # Pass to HCG
    set req.backend_hint = hcg;
}

sub vcl_backend_response {
    # Respect Drupal cache tags
    if (beresp.http.X-Drupal-Cache-Tags) {
        set beresp.http.X-VC-Cache-Tags = beresp.http.X-Drupal-Cache-Tags;
    }
}
```

---

## ✅ Compatibility Checklist

Before deploying HCG with a CMS:

- [ ] Test admin panel access
- [ ] Test AJAX endpoints
- [ ] Verify session persistence
- [ ] Check file uploads work
- [ ] Test REST API endpoints
- [ ] Verify ACME challenges work
- [ ] Check security headers present
- [ ] Test CORS if needed
- [ ] Verify cache headers respected
- [ ] Test under load

---

## 🤝 Community Policies

Share your CMS policy configurations:
- [WordPress policies on hub.hyperpolymath.org](https://hub.hyperpolymath.org/wordpress)
- [Drupal policies](https://hub.hyperpolymath.org/drupal)
- [Moodle policies](https://hub.hyperpolymath.org/moodle)

**Submit yours**: `hcg policy publish wordpress-my-config.yaml`

---

**tl;dr**: HCG plays nice with WordPress, Drupal, Moodle, and standard web infrastructure. It preserves what matters, bypasses admin paths intelligently, and respects web standards like .well-known/ and security headers.
