; SPDX-License-Identifier: MPL-2.0
;; guix.scm — GNU Guix package definition for http-capability-gateway
;; Usage: guix shell -f guix.scm

(use-modules (guix packages)
             (guix build-system gnu)
             (guix licenses))

(package
  (name "http-capability-gateway")
  (version "0.1.0")
  (source #f)
  (build-system gnu-build-system)
  (synopsis "http-capability-gateway")
  (description "http-capability-gateway — part of the hyperpolymath ecosystem.")
  (home-page "https://github.com/hyperpolymath/http-capability-gateway")
  (license mpl2.0))
