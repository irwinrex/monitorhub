// prometheus.remote_write "mimir" {
//   endpoint {
//     url = env("ALLOY_MIMIR_URL")
//     basic_auth {
//       username = env("ALLOY_AUTH_USERNAME")
//       password = env("ALLOY_AUTH_PASSWORD")
//     }
//   }
// }
//
// prometheus.scrape "django_app" {
//   targets = [
//     {"__address__" = "django:8000", "job" = "local-service"},
//   ]
//   forward_to = [prometheus.remote_write.mimir.receiver]
// }

// -------------------------------------------------------------
// Grafana Alloy → Loki (Docker logs) configuration
// -------------------------------------------------------------

// 1. Discover all Docker containers
discovery.docker "all" {
  host = "unix:///var/run/docker.sock"
}

// 2. Scrape logs from Docker containers
loki.source.docker "docker_logs" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.docker.all.targets
  forward_to = [loki.process.enrich_labels.receiver]
}

// 3. Enrich logs with custom labels (including service_name)
loki.process "enrich_labels" {
  stage.static_labels {
    values = {
      local_service = "django-app",
    }
  }
  forward_to = [loki.write.send_to_loki.receiver]
}

// 4. Write logs to Loki
loki.write "send_to_loki" {
  endpoint {
    url = env("ALLOY_LOKI_URL")
    basic_auth {
      username = env("ALLOY_AUTH_USERNAME")
      password = env("ALLOY_AUTH_PASSWORD")
    }
    tls_config {
      insecure_skip_verify = env("ALLOY_TLS_INSECURE") == "true"
    }
  }
}
