/// `pgadmin/tools`: the parent of the tool modules, translations and `initialize`.
module pgadmin.tools;

import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.utils.constants;
import pgadmin.web.flask;
import pgadmin.web.http;

final class ToolsModule : Blueprint
{
    /// The tool blueprints, registered at the application level (like `app.register_blueprint(module)`).
    Blueprint[] tools;

    this()
    {
        super("tools");
    }

    override string[] getExposedUrlEndpoints() => ["tools.initialize"];

    override void setup()
    {
        route("/", "index", ["GET"], (Dict a) => badRequest(gettext("This URL cannot be requested directly.")));
        route("/translations.js", "translations", ["GET"], (Dict a) {
            auto cat = new Dict;
            auto r = renderTemplate("js/translations.js", ["translations": Value(cat)]);
            return new Response(r, 200, MIMETYPE_APP_JS);
        }, true);
        route("/initialize/", "initialize", ["GET"], (Dict a) => makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.newDict()));
    }

    override void register(FlaskApp a)
    {
        super.register(a);
        foreach (t; tools)
            a.registerBlueprint(t);
    }
}
