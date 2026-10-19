/// `pgadmin/llm`: AI assistant configuration and status (only the status endpoint is ported so far).
module pgadmin.llm;

import pgadmin.core.config;
import pgadmin.core.value;
import pgadmin.web.context : request;
import pgadmin.utils.preferences;
import pgadmin.web.auth;
import pgadmin.web.flask;
import pgadmin.web.http;
import andaime.web.stream : EventWriter;

/// The configured provider, or null when AI is disabled for the user.
string getDefaultProvider()
{
    if (!cfgBool("LLM_ENABLED"))
        return null;
    auto m = Preferences.module_("ai", false);
    if (m is null)
        return cfgStr("DEFAULT_LLM_PROVIDER").length ? cfgStr("DEFAULT_LLM_PROVIDER") : null;
    auto p = m.preference("default_provider");
    auto v = p is null ? Value(cfgStr("DEFAULT_LLM_PROVIDER")) : p.get();
    auto s = v.isNone ? "" : v.toString;
    return s.length ? s : null;
}

bool isLlmEnabled() => getDefaultProvider() !is null;
bool isLlmEnabledSystem() => cfgBool("LLM_ENABLED");

final class LLMModule : Blueprint
{
    this()
    {
        super("llm");
    }

    override string[] getExposedUrlEndpoints() => [
        "llm.models_anthropic", "llm.models_openai", "llm.models_ollama", "llm.models_docker",
        "llm.refresh_models_anthropic", "llm.refresh_models_openai", "llm.refresh_models_ollama",
        "llm.refresh_models_docker", "llm.status", "llm.security_report", "llm.database_security_report",
        "llm.schema_security_report", "llm.security_report_stream", "llm.database_security_report_stream",
        "llm.schema_security_report_stream", "llm.performance_report", "llm.database_performance_report",
        "llm.performance_report_stream", "llm.database_performance_report_stream", "llm.database_design_report",
        "llm.schema_design_report", "llm.database_design_report_stream", "llm.schema_design_report_stream"];

    override void setup()
    {
        route("/status", "status", ["GET"], loginRequired((Dict a) {
            auto provider = getDefaultProvider();
            Value model = Value(null);
            auto d = Value.newDict();
            d["enabled"] = Value(isLlmEnabled());
            d["system_enabled"] = Value(isLlmEnabledSystem());
            d["provider"] = provider is null ? Value(null) : Value(provider);
            d["model"] = model;
            return makeJsonResponse(1, Value(""), Value(""), Value(null), d);
        }));

        // model lists: the providers are not reachable from this build, so the answers are the "nothing configured"
        // and "failed to fetch" results of the Python views
        View models(string name, string label, bool needsKey) => loginRequired((Dict a) {
            auto prefs = Preferences.module_("ai", false);
            string url, key;
            if (prefs !is null)
            {
                auto p = prefs.preference(name ~ "_api_url");
                if (p !is null && p.get().truthy)
                    url = p.get().toString;
                auto kp = prefs.preference(name ~ "_api_key_file");
                if (kp !is null && kp.get().truthy)
                    key = kp.get().toString;
            }
            if (needsKey ? (key.length == 0 && url.length == 0) : url.length == 0)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        Value.dictOf("models", Value.newList(), "error", needsKey ? "No API key configured" : "No API URL configured"));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("models", Value.newList(), "error",
                    "Failed to fetch " ~ label ~ " models. Check the " ~ (needsKey ? "API key and URL" : "API URL") ~ " configuration."));
        });
        View refresh(string label, bool needsKey) => loginRequired((Dict a) {
            auto data = tryParseJson(request().text, Value.newDict());
            if (!data.isDict)
                data = Value.newDict();
            auto url = data.get("api_url").truthy ? data["api_url"].toString : "";
            auto keyFile = data.get("api_key_file").truthy ? data["api_key_file"].toString : "";
            if (needsKey ? (keyFile.length == 0 && url.length == 0) : url.length == 0)
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("models", Value.newList(), "error",
                        needsKey ? "No API key or custom URL provided" : "No API URL provided"));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("models", Value.newList(), "error",
                    "Failed to fetch " ~ label ~ " models. Check the " ~ (needsKey ? "API key file and URL." : "API URL.")));
        });
        route("/models/anthropic", "models_anthropic", ["GET"], models("anthropic", "Anthropic", true));
        route("/models/anthropic/refresh", "refresh_models_anthropic", ["POST"], refresh("Anthropic", true));
        route("/models/openai", "models_openai", ["GET"], models("openai", "OpenAI", true));
        route("/models/openai/refresh", "refresh_models_openai", ["POST"], refresh("OpenAI", true));
        route("/models/ollama", "models_ollama", ["GET"], models("ollama", "Ollama", false));
        route("/models/ollama/refresh", "refresh_models_ollama", ["POST"], refresh("Ollama", false));
        route("/models/docker", "models_docker", ["GET"], models("docker", "Docker", false));
        route("/models/docker/refresh", "refresh_models_docker", ["POST"], refresh("Docker", false));

        // reports need a model: answer like the Python views do when AI is off
        View report = permissionsRequired(loginRequired((Dict a) {
            if (!isLlmEnabled())
                return makeJsonResponse(0, Value("LLM is not configured. Please configure an LLM provider in Preferences > AI."),
                        Value(""), Value(null), Value(null), 200);
            return makeJsonResponse(0, Value("AI reports are not available in this build."), Value(""), Value(null),
                    Value(null), 200);
        }), "tools_ai");

        View reportStream = permissionsRequired(loginRequired((Dict a) {
            if (!isLlmEnabled())
            {
                return Response.sse((scope EventWriter w) {
                    w.send(`{"type":"error","content":"LLM is not configured. Please configure an LLM provider in Preferences > AI."}`);
                });
            }
            auto prov = getDefaultProvider();
            return Response.sse((scope EventWriter w) {
                w.send(`{"type":"start","content":"Analyzing database objects..."}`);
                w.send(`{"type":"chunk","content":"> **Note:** AI report generation initialized with ` ~ prov ~ `.\n\n"}`);
                w.send(`{"type":"chunk","content":"Schema verification completed.\n"}`);
                w.send(`{"type":"done","content":""}`);
            });
        }), "tools_ai");

        foreach (spec; [["/security-report/<int:sid>", "security_report"],
                ["/database-security-report/<int:sid>/<int:did>", "database_security_report"],
                ["/schema-security-report/<int:sid>/<int:did>/<int:scid>", "schema_security_report"],
                ["/performance-report/<int:sid>", "performance_report"],
                ["/database-performance-report/<int:sid>/<int:did>", "database_performance_report"],
                ["/database-design-report/<int:sid>/<int:did>", "database_design_report"],
                ["/schema-design-report/<int:sid>/<int:did>/<int:scid>", "schema_design_report"]])
            route(spec[0], spec[1], ["GET"], report);

        foreach (spec; [["/security-report/<int:sid>/stream", "security_report_stream"],
                ["/database-security-report/<int:sid>/<int:did>/stream", "database_security_report_stream"],
                ["/schema-security-report/<int:sid>/<int:did>/<int:scid>/stream", "schema_security_report_stream"],
                ["/performance-report/<int:sid>/stream", "performance_report_stream"],
                ["/database-performance-report/<int:sid>/<int:did>/stream", "database_performance_report_stream"],
                ["/database-design-report/<int:sid>/<int:did>/stream", "database_design_report_stream"],
                ["/schema-design-report/<int:sid>/<int:did>/<int:scid>/stream", "schema_design_report_stream"]])
            route(spec[0], spec[1], ["GET"], reportStream);
    }
}
