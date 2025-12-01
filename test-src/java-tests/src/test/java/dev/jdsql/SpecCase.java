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
    public int expected_exit;
    public Boolean should_error;
    // Upstream spec provides CLI-style args (e.g., -set, -opts=JSON)
    public java.util.List<String> args;
}
