package com.example.company.unit;

import static org.hamcrest.Matchers.not;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.company.config.GlobalExceptionHandler;
import com.example.company.exception.ApplicationException;
import feign.FeignException;
import feign.Request;
import feign.Response;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.cloud.client.circuitbreaker.NoFallbackAvailableException;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpStatus;
import org.springframework.test.context.TestConstructor;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@WebMvcTest(controllers = GlobalExceptionHandlerTest.ThrowingController.class)
@Import({GlobalExceptionHandler.class, GlobalExceptionHandlerTest.ThrowingController.class})
@TestConstructor(autowireMode = TestConstructor.AutowireMode.ALL)
class GlobalExceptionHandlerTest {

    private final MockMvc mockMvc;

    GlobalExceptionHandlerTest(MockMvc mockMvc) {
        this.mockMvc = mockMvc;
    }

    @Test
    void unknownPathIsA404Problem() throws Exception {
        mockMvc.perform(get("/nope"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.status").value(404));
    }

    @Test
    void wrongMethodIsA405Problem() throws Exception {
        mockMvc.perform(post("/throw/ok")).andExpect(status().isMethodNotAllowed());
    }

    @Test
    void unparsableParameterIsA400Problem() throws Exception {
        mockMvc.perform(get("/throw/typed").param("n", "abc"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.status").value(400));
    }

    @Test
    void unsupportedContentTypeIsA415Problem() throws Exception {
        mockMvc.perform(post("/throw/body").contentType("text/plain").content("x"))
                .andExpect(status().isUnsupportedMediaType())
                .andExpect(jsonPath("$.status").value(415));
    }

    @Test
    void responseStatusExceptionKeepsItsStatus() throws Exception {
        mockMvc.perform(get("/throw/status"))
                .andExpect(status().isPaymentRequired())
                .andExpect(jsonPath("$.detail").value("pay up"));
    }

    @Test
    void circuitBreakerWithoutFallbackIsA502() throws Exception {
        mockMvc.perform(get("/throw/no-fallback"))
                .andExpect(status().isBadGateway())
                .andExpect(jsonPath("$.detail").value("Upstream service unavailable"));
    }

    @Test
    void feignFailureIsA502WithoutUpstreamText() throws Exception {
        mockMvc.perform(get("/throw/feign"))
                .andExpect(status().isBadGateway())
                .andExpect(jsonPath("$.detail").value("Upstream service unavailable"))
                .andExpect(content().string(not(org.hamcrest.Matchers.containsString("secret-upstream-body"))));
    }

    @Test
    void applicationExceptionKeepsItsStatusAndMessage() throws Exception {
        mockMvc.perform(get("/throw/app"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.detail").value("already exists"));
    }

    @Test
    void unexpectedExceptionIsAGeneric500() throws Exception {
        mockMvc.perform(get("/throw/boom"))
                .andExpect(status().isInternalServerError())
                .andExpect(jsonPath("$.detail").value("Something went wrong"));
    }

    @RestController
    static class ThrowingController {

        @GetMapping("/throw/ok")
        String ok() {
            return "ok";
        }

        @GetMapping("/throw/typed")
        String typed(@RequestParam int n) {
            return "n=" + n;
        }

        @GetMapping("/throw/feign")
        String feign() {
            var request = Request.create(
                    Request.HttpMethod.GET, "http://upstream", Map.of(), null, StandardCharsets.UTF_8, null);
            var response = Response.builder()
                    .status(503)
                    .reason("down")
                    .request(request)
                    .body("secret-upstream-body", StandardCharsets.UTF_8)
                    .build();
            throw FeignException.errorStatus("Upstream#call()", response);
        }

        @PostMapping(value = "/throw/body", consumes = "application/json")
        String body(@RequestBody Map<String, String> body) {
            return "ok";
        }

        @GetMapping("/throw/status")
        String status() {
            throw new ResponseStatusException(HttpStatus.PAYMENT_REQUIRED, "pay up");
        }

        @GetMapping("/throw/no-fallback")
        String noFallback() {
            throw new NoFallbackAvailableException("circuit open", new RuntimeException("upstream body"));
        }

        @GetMapping("/throw/app")
        String app() {
            throw new ApplicationException(HttpStatus.CONFLICT, "already exists");
        }

        @GetMapping("/throw/boom")
        String boom() {
            throw new IllegalStateException("boom");
        }
    }
}
