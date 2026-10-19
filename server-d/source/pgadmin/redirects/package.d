/// `pgadmin/redirects`: `/` goes to the browser, `/favicon.ico` to the static icon.
module pgadmin.redirects;

import pgadmin.core.value;
import pgadmin.web.flask;
import pgadmin.web.http;
import pgadmin.web.auth;

final class RedirectModule : Blueprint
{
    this()
    {
        super("redirects", "/");
    }

    override void setup()
    {
        route("/", "index", ["GET"], (Dict a) {
            if (!pgaLoginRequired())
                return loginRedirect();
            return redirect(flaskApp.urlFor("browser.index"));
        });
        route("favicon.ico", "favicon", ["GET"], (Dict a) {
            auto d = new Dict;
            d["filename"] = "favicon.ico";
            return redirect(flaskApp.urlFor("static", d));
        }, true);
    }
}
