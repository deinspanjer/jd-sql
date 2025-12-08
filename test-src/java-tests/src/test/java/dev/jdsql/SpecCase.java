package dev.jdsql;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

@JsonIgnoreProperties(ignoreUnknown = true)
public class SpecCase {
    public String name;
    public String description;
    public String category;
    public String content_a;
    public String content_b;
    public String expected_diff;
    // For jd-sql-custom cases, assertions may be against a generic result value
    // (boolean/text/json compact). Use expected_result when not asserting via expected_diff/exit.
    public String expected_result;
    public int expected_exit;
    public Boolean should_error;
    // Upstream spec provides CLI-style args (e.g., -set, -opts=JSON)
    public java.util.List<String> args;
    // jd-sql custom extension: optionally select which SQL entrypoint to call
    // Allowed values: "jd_diff" (default) or "jd_diff_text" for text output
    public String sql_function;
    // Optional: explicit args for sql_function (e.g., formats for translate)
    public java.util.List<String> sql_function_args;
}
