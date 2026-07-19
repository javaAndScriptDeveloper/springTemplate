package com.example.company.support;

import java.util.List;
import org.instancio.Instancio;

/**
 * Central entry point for test data. Prefer building objects here (via Instancio) over hand-constructing them, so
 * tests stay focused on the fields they actually assert on. Combine with {@code @ExtendWith(InstancioExtension.class)}
 * for reproducible, per-test random seeds.
 */
public final class Fixtures {

    private Fixtures() {}

    /** Fully-populated random instance of {@code type}. */
    public static <T> T create(Class<T> type) {
        return Instancio.create(type);
    }

    /** {@code size} random instances of {@code type}. */
    public static <T> List<T> createList(Class<T> type, int size) {
        return Instancio.ofList(type).size(size).create();
    }
}
