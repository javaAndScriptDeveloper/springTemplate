package com.example.company.unit;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;

/**
 * Guards the committed Grafana assets under {@code deploy/grafana}: they are hand-edited JSON that only fails at
 * push time otherwise. Every query must reference a metric this application (or its backup sidecar) exports, and
 * every datasource reference must use the shared uid so one file renders both locally and in Grafana Cloud.
 */
class DashboardJsonTest {

    private static final Path GRAFANA_DIR = Path.of("deploy", "grafana");
    private static final String DATASOURCE_UID = "grafanacloud-prom";
    private static final Pattern KNOWN_METRICS = Pattern.compile(
            "app_build_info|app_backup_|http_server_requests_seconds|jvm_|hikaricp_|logback_events_total|process_|"
                    + "system_cpu|\\bup\\b|resilience4j_|tomcat_");

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void dashboardHasStableUidAndEnvVariable() throws IOException {
        var dashboard = mapper.readTree(
                GRAFANA_DIR.resolve("dashboards/app-overview.json").toFile());

        assertThat(dashboard.path("uid").asText()).isEqualTo("app-overview");
        var variables = dashboard.path("templating").path("list");
        assertThat(variables).anyMatch(v -> v.path("name").asText().equals("env"));
        assertThat(dashboard.path("panels")).isNotEmpty();
    }

    @Test
    void everyDatasourceReferenceUsesTheSharedUid() throws IOException {
        var uids = new ArrayList<String>();
        for (var file : jsonFiles()) {
            collect(mapper.readTree(file.toFile()), "datasource", node -> {
                // Grafana's built-in "Annotations & Alerts" source is not a Prometheus reference.
                if (node.has("uid") && !"grafana".equals(node.path("type").asText())) {
                    uids.add(node.get("uid").asText());
                }
            });
        }

        assertThat(uids).isNotEmpty().allMatch(DATASOURCE_UID::equals);
    }

    @Test
    void everyQueryReferencesAMetricTheAppExports() throws IOException {
        var offenders = new ArrayList<String>();
        for (var file : jsonFiles()) {
            collect(mapper.readTree(file.toFile()), "expr", node -> {
                var expr = node.asText();
                if (!expr.isBlank() && !KNOWN_METRICS.matcher(expr).find()) {
                    offenders.add(file.getFileName() + ": " + expr);
                }
            });
        }

        assertThat(offenders).isEmpty();
    }

    @Test
    void backupStaleAlertFiresAfterTwelveHoursAndStaysQuietWhenBackupsAreOff() throws IOException {
        var rules = mapper.readTree(GRAFANA_DIR.resolve("alerting/rules.json").toFile());
        var stale = element(rules, "title", "BackupStale");

        // No data means the backup profile is off, which is a valid configuration, not an incident.
        assertThat(stale.path("noDataState").asText()).isEqualTo("OK");
        assertThat(stale.toString()).contains("app_backup_last_success_timestamp_seconds");
        var threshold = element(stale.path("data"), "refId", "C")
                .path("model")
                .path("conditions")
                .get(0)
                .path("evaluator")
                .path("params")
                .get(0);
        assertThat(threshold.asInt()).isEqualTo(43200);
    }

    @Test
    void dashboardShowsTheAgeOfTheLastBackup() throws IOException {
        var dashboard = mapper.readTree(
                GRAFANA_DIR.resolve("dashboards/app-overview.json").toFile());

        var panel = element(dashboard.path("panels"), "title", "Last successful backup");
        assertThat(panel.toString()).contains("app_backup_last_success_timestamp_seconds");
    }

    private static JsonNode element(JsonNode array, String field, String value) {
        for (var node : array) {
            if (node.path(field).asText().equals(value)) {
                return node;
            }
        }
        throw new AssertionError("no element with " + field + "=" + value);
    }

    private static List<Path> jsonFiles() throws IOException {
        try (Stream<Path> files = Files.walk(GRAFANA_DIR)) {
            return files.filter(p -> p.toString().endsWith(".json")).toList();
        }
    }

    /** Depth-first visit of every field named {@code key}. */
    private static void collect(JsonNode node, String key, java.util.function.Consumer<JsonNode> visitor) {
        if (node.isObject()) {
            node.properties().forEach(entry -> {
                if (entry.getKey().equals(key)) {
                    visitor.accept(entry.getValue());
                }
                collect(entry.getValue(), key, visitor);
            });
        } else if (node.isArray()) {
            node.forEach(child -> collect(child, key, visitor));
        }
    }
}
