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
    public String compliance_level;
    public Boolean should_error;
}
