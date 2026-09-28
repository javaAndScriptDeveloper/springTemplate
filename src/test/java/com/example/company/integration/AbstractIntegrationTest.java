package com.example.company.integration;

import com.example.company.TestcontainersConfiguration;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.TestConstructor;

/**
 * Base class for integration tests. Boots the full Spring context against a real PostgreSQL started by
 * Testcontainers and configures {@code MockMvc} for driving the web layer.
 *
 * <p>Subclasses receive their collaborators through the constructor ({@link TestConstructor} autowires it), matching
 * the constructor-injection rule the ArchUnit tests enforce on production code.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Import(TestcontainersConfiguration.class)
@TestConstructor(autowireMode = TestConstructor.AutowireMode.ALL)
public abstract class AbstractIntegrationTest {}
