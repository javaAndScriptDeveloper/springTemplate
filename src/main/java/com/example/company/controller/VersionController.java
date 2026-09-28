package com.example.company.controller;

import com.example.company.config.AppInfoProperties;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Public build identity. CI's deploy job polls this through Caddy until every replica reports the released revision;
 * it is the one piece of build metadata served on the application port rather than the private management port.
 */
@RestController
public class VersionController {

    private final AppInfoProperties info;

    public VersionController(AppInfoProperties info) {
        this.info = info;
    }

    @GetMapping("/version")
    public Map<String, String> version() {
        return Map.of("version", info.version(), "revision", info.revision());
    }
}
