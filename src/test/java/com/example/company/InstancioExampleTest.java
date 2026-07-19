package com.example.company;

import static org.assertj.core.api.Assertions.assertThat;
import static org.instancio.Select.field;

import com.example.company.support.Fixtures;
import java.util.List;
import org.instancio.Instancio;
import org.instancio.junit.InstancioExtension;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

/**
 * Reference for the Instancio test-data convention. {@link InstancioExtension} reports the random seed on failure and
 * lets you reproduce it, so random data stays debuggable. Replace {@code Customer} with your own domain types.
 */
@ExtendWith(InstancioExtension.class)
class InstancioExampleTest {

    record Customer(Long id, String name, String email, boolean active) {}

    @Test
    void createsFullyPopulatedObject() {
        Customer customer = Fixtures.create(Customer.class);

        assertThat(customer.id()).isNotNull();
        assertThat(customer.name()).isNotBlank();
        assertThat(customer.email()).isNotBlank();
    }

    @Test
    void customizesOnlyTheFieldsUnderTest() {
        Customer customer = Instancio.of(Customer.class)
                .set(field(Customer::name), "Ada Lovelace")
                .set(field(Customer::active), true)
                .create();

        assertThat(customer.name()).isEqualTo("Ada Lovelace");
        assertThat(customer.active()).isTrue();
    }

    @Test
    void createsCollections() {
        List<Customer> customers = Fixtures.createList(Customer.class, 5);

        assertThat(customers).hasSize(5).allSatisfy(c -> assertThat(c.email()).isNotBlank());
    }
}
