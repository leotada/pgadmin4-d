/// `pgadmin/misc/file_manager`: the file selection dialogs (browse, create folders, upload, download, rename...).
module pgadmin.misc.file_manager;

import core.sys.posix.unistd : access, R_OK, W_OK;
import std.algorithm : canFind, endsWith, sort, startsWith;
import std.array : join, replace;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.file : append, DirEntry, dirEntries, exists, getSize, isDir, isFile, mkdir, read, remove, rmdir, rename, SpanMode, timeLastModified,
    write, readText;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, expandTilde, isAbsolute;
import std.random : uniform;
import std.string : lastIndexOf, strip, toStringz;
import std.uri : decodeComponent;
import pgadmin.browser.common;
import pgadmin.misc.file_manager.fm_state;
import pgadmin.utils.paths : getStorageDirectory;
import pgadmin.utils.preferences : Preferences;
import pgadmin.web.flask;

private immutable platformType = "linux";

/// `sizeof_fmt`
string sizeofFmt(double num)
{
    foreach (unit; ["", "k", "M", "G", "T", "P", "E", "Z"])
    {
        if (num > -1024.0 && num < 1024.0)
            return format("%3.1f %s%s", num, unit, "B");
        num /= 1024.0;
    }
    return format("%.1f %s%s", num, "Y", "B");
}

/// `time.ctime(t)`
private string ctime(SysTime t)
{
    static immutable days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    static immutable months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    t = t.toLocalTime();
    return format("%s %s %2d %02d:%02d:%02d %d", days[cast(int) t.dayOfWeek == 0 ? 6 : cast(int) t.dayOfWeek - 1],
            months[cast(int) t.month - 1], t.day, t.hour, t.minute, t.second, t.year);
}

/// `splitext` of the module (a few compound extensions, without the dot)
private string splitExt(string path)
{
    foreach (ext; [".tar.gz", ".tar.bz2"])
        if (path.endsWith(ext))
            return ext[1 .. $];
    auto b = baseName(path);
    auto dot = b.lastIndexOf('.');
    if (dot <= 0)
        return "";
    return b[dot + 1 .. $];
}

private bool isFolderHidden(string path) => baseName(path).startsWith(".");

private Preferences fmPrefs() => Preferences.module_("file_manager");

private Value fmPref(string name)
{
    auto p = fmPrefs().preference(name);
    if (p is null)
        throw new Exception("unknown preference file_manager." ~ name);
    return p.get();
}

private void fmPrefSet(string name, Value v)
{
    auto p = fmPrefs().preference(name);
    string err;
    if (p !is null)
        p.set(v, err);
}

private Response unauthorizedMsg(string msg) => makeJsonResponse(0, Value(msg), Value(""), Value(null), Value(null), 401);

private string unquote(string s)
{
    try
        return decodeComponent(s);
    catch (Exception)
        return s;
}

/// Raised where Python raises PermissionError.
class PermissionError : Exception
{
    this(string msg)
    {
        super(msg);
    }
}

/// `Filemanager.get_abs_path(in_dir, path)`
string getAbsPath(string inDir, string path)
{
    if (!cfgBool("SERVER_MODE") || inDir is null)
        return path;
    if (path == "/" || path == "\\")
        return inDir.endsWith("/") ? inDir : inDir ~ "/";
    if (inDir.endsWith("/") || inDir.endsWith("\\"))
    {
        if (path.startsWith("/") || path.startsWith("\\"))
            return inDir[0 .. $ - 1] ~ path;
        return inDir ~ "/" ~ path;
    }
    if (path.startsWith("/") || path.startsWith("\\"))
        return inDir ~ path;
    return inDir ~ "/" ~ path;
}

/// `Filemanager.check_access_permission(in_dir, path, skip_permission_check)`
void checkAccessPermission(string inDir, string path, bool skip = false)
{
    if (!cfgBool("SERVER_MODE") || skip)
        return;
    if (inDir is null)
        inDir = "";
    auto origPath = buildNormalizedPath(absolutePath(getAbsPath(inDir, path)));
    if (inDir.length)
    {
        if (inDir.endsWith("/"))
            inDir = inDir[0 .. $ - 1];
        inDir = buildNormalizedPath(absolutePath(inDir));
    }
    if (!(origPath == inDir || origPath.startsWith(inDir ~ "/") || inDir.length == 0))
        throw new PermissionError(gettext("Access denied (%s)").replace("%s", path));
}

/// The `filename_with_file_manager_path(file, create_file, skip_permission_check)` of `pgadmin/utils`.
string filenameWithFileManagerPath(string file, bool createFile = false, bool skipPermissionCheck = false)
{
    string dirName_ = "";
    string file_ = file;
    auto shared_ = ConfigAccess.get("SHARED_STORAGE");
    if (shared_.isList && shared_.length)
        foreach (sd; shared_.list.items)
        {
            auto prefix = sd["name"].toString ~ ":";
            if (file.canFind(prefix))
            {
                auto parts = file.split(":/");
                dirName_ = parts[0];
                file_ = parts[1];
                break;
            }
        }
    string lastStorage;
    try
        lastStorage = fmPref("last_storage").toString;
    catch (Exception)
        lastStorage = MY_STORAGE;
    string storageDir;
    if (lastStorage != MY_STORAGE)
        storageDir = getStorageDirectory(lastStorage);
    else
        storageDir = getStorageDirectory();
    checkAccessPermission(storageDir, file_, skipPermissionCheck);
    if (storageDir !is null)
    {
        while (file_.length && (file_[0] == '/' || file_[0] == '\\'))
            file_ = file_[1 .. $];
        file_ = buildPath(storageDir, file_);
    }
    else if (!isAbsolute(file_))
        file_ = buildPath(buildNormalizedPath(expandTilde("~")), file_);
    if (createFile)
        append(file_, "");
    return file_;
}

/// `Filemanager`
final class Filemanager
{
    string transId;
    string dir;
    string sharedDir;

    this(string transId, string ss = "")
    {
        this.transId = transId;
        dir = getStorageDirectory();
        sharedDir = getStorageDirectory(ss);
    }

    static string getClosestParent(string storageDir, string lastDir)
    {
        if (lastDir.length > 1 && (lastDir.endsWith("/") || lastDir.endsWith("\\")))
            lastDir = lastDir[0 .. $ - 1];
        while (lastDir.length)
        {
            if (exists(storageDir.length ? storageDir : lastDir))
                break;
            auto idx = lastDir.lastIndexOf('/');
            lastDir = idx < 0 ? "" : lastDir[0 .. idx];
        }
        if (!lastDir.endsWith("/"))
            lastDir ~= "/";
        return lastDir;
    }

    static bool checkCapabilityPermission(string capability)
    {
        if (capability == "create")
            return userHasPermission(currentUserId(), "storage_add_folder");
        if (capability == "delete")
            return userHasPermission(currentUserId(), "storage_remove_folder");
        return true;
    }

    /// `create_new_transaction(params)`: returns the transaction id.
    static string createNewTransaction(Value params)
    {
        auto fmType = params["dialog_type"].toString;
        if (params.contains("init_path"))
            throw new Exception("_Preference.get() takes 1 positional argument but 2 were given");
        auto storageDir = getStorageDirectory();
        bool showVolumes = storageDir is null || storageDir.length == 0;
        auto suppTypes = params.get("supported_types", Value.newList());
        Value[] allowCreate = checkCapabilityPermission("create") ? [Value("create")] : null;
        Value[] allowDelete = checkCapabilityPermission("delete") ? [Value("delete")] : null;
        Value caps;
        bool filesOnly, foldersOnly;
        string title;
        Value[] cat(Value[] a, Value[] b) => a ~ b;
        switch (fmType)
        {
        case "select_file":
            caps = Value(cat([Value("select_file"), Value("rename"), Value("upload")], allowDelete));
            filesOnly = true;
            title = gettext("Select File");
            break;
        case "select_folder":
            caps = Value(cat([Value("select_folder"), Value("rename")], allowCreate));
            foldersOnly = true;
            title = gettext("Select Folder");
            break;
        case "open_file":
            caps = Value([Value("open_file")]);
            filesOnly = true;
            title = gettext("Select File");
            break;
        case "create_file":
            caps = Value(cat([Value("select_file"), Value("rename")], allowCreate));
            filesOnly = true;
            title = gettext("Create File");
            break;
        case "storage_dialog":
            caps = Value(cat(cat([Value("select_folder"), Value("select_file"), Value("download"), Value("rename"),
                    Value("upload")], allowDelete), allowCreate));
            filesOnly = true;
            title = gettext("Storage Manager");
            break;
        default:
            throw new Exception("'" ~ fmType ~ "'");
        }
        string homedir = cfgBool("SERVER_MODE") ? "/" : buildNormalizedPath(expandTilde("~")) ~ "/";
        auto lastDirV = fmPref("last_directory_visited");
        string lastDir = lastDirV.isNone ? null : lastDirV.toString;
        auto lastSsName = fmPref("last_storage").toString;
        string lastSs;
        auto sharedStorage = ConfigAccess.get("SHARED_STORAGE");
        if (lastSsName.length && lastSsName != MY_STORAGE && sharedStorage.isList && sharedStorage.length > 0)
        {
            foreach (sd; sharedStorage.list.items)
                if (sd["name"] == Value(lastSsName))
                    lastSs = sd["path"].toString;
            if (lastSs is null)
                lastSs = storageDir;
        }
        else
        {
            if (lastSsName != MY_STORAGE)
            {
                lastDir = "/";
                fmPrefSet("last_storage", Value(MY_STORAGE));
            }
            lastSs = storageDir;
        }
        bool checkDirExists;
        if (lastDir is null)
            lastDir = "/";
        else
            checkDirExists = true;
        if ((!cfgBool("SERVER_MODE") && lastDir == "/") || lastDir == "/")
            lastDir = homedir;
        if (checkDirExists)
            lastDir = getClosestParent(lastSs, lastDir);
        auto fileSizeLimit = fmPref("file_upload_size");
        auto configs = Value.dictOf("fileroot", lastDir, "homedir", homedir, "storage_folder", lastSsName,
                "dialog_type", fmType, "title", title, "upload", Value.dictOf("multiple", true, "fileSizeLimit", fileSizeLimit),
                "capabilities", caps, "security", Value.dictOf("uploadPolicy", "", "uploadRestrictions", suppTypes),
                "files_only", filesOnly, "folders_only", foldersOnly, "supported_types", suppTypes, "platform_type",
                platformType, "show_volumes", showVolumes);
        auto transId = to!string(uniform(1, 9999999));
        fmStore(transId, configs);
        return transId;
    }

    static Value getTransactionSelection(string transId) => fmGet(transId);

    static void releaseTransaction(string transId)
    {
        fmRelease(transId);
    }

    private static bool skipFileExtension(Value fileType, Value supported, bool foldersOnly, string ext)
    {
        if (fileType.isNone || fileType == Value("*"))
            return false;
        return foldersOnly || (supported.length > 0 && !supported.contains(Value(ext))) || fileType != Value(ext);
    }

    static Value getFilesInPath(bool showHidden, Value filesOnly, bool foldersOnly, Value supported, Value fileType, string userDir,
            string origPath)
    {
        Value[] files;
        string[] names;
        foreach (e; dirEntries(origPath, SpanMode.shallow))
            names ~= baseName(e.name);
        names.sort();
        foreach (f; names)
        {
            auto systemPath = buildPath(origPath, f);
            if (!showHidden && isFolderHidden(systemPath))
                continue;
            string userPath = buildPath(userDir, f);
            string created, modified, fileExtension;
            try
            {
                import std.file : timeCreated = timeLastModified;
                auto mt = timeLastModified(systemPath);
                created = ctime(mt);
                modified = ctime(mt);
                fileExtension = splitExt(systemPath);
            }
            catch (Exception)
                continue;
            long protected_;
            if (access(systemPath.toStringz, R_OK) != 0 || access(systemPath.toStringz, W_OK) != 0)
                protected_ = 1;
            long size;
            try
                size = getSize(systemPath);
            catch (Exception)
                size = 0;
            if (isDir(systemPath))
            {
                if (filesOnly == Value("true"))
                    continue;
                fileExtension = "dir";
            }
            else if (skipFileExtension(fileType, supported, foldersOnly, fileExtension))
                continue;
            files ~= Value.dictOf("Filename", f, "Path", userPath, "file_type", fileExtension, "Protected", protected_,
                    "Properties", Value.dictOf("Date Created", created, "Date Modified", modified, "Size", sizeofFmt(size)));
        }
        return Value(files);
    }

    /// `list_filesystem(...)`: the entries (or an error response)
    Response listFilesystem(string inDir, string path, Value transData, Value fileType, bool showHidden, out Value files)
    {
        path = unquote(path);
        checkAccessPermission(inDir, path);
        auto origPath = getAbsPath(inDir, path);
        if (!exists(origPath))
            return makeJsonResponse(1, Value(gettext("'%s' file does not exist.").replace("%s", path)), Value(""), Value(null),
                    Value(null), 404);
        auto foldersOnly = transData.get("folders_only", Value("")).truthy;
        auto filesOnly = transData.get("files_only", Value(""));
        auto supported = transData.get("supported_types", Value.newList());
        origPath = unquote(origPath);
        try
            files = getFilesInPath(showHidden, filesOnly, foldersOnly, supported, fileType, path, origPath);
        catch (Exception e)
            return unauthorizedMsg(e.msg);
        return null;
    }

    bool validateRequest(string capability)
    {
        auto td = getTransactionSelection(transId);
        if (td.isNone)
            throw new Exception("'NoneType' object is not subscriptable");
        return td.get("capabilities", Value.newList()).contains(Value(capability)) ? checkCapabilityPermission(capability) : false;
    }

    private string theDir() => sharedDir.length ? sharedDir : (dir !is null ? dir : "");

    /// `getfolder`
    Response getfolder(Value kw, out Value result)
    {
        auto td = getTransactionSelection(transId);
        if (td.isNone)
            throw new Exception("'NoneType' object has no attribute 'get'");
        string the;
        if (cfgBool("SERVER_MODE"))
        {
            auto ss = ConfigAccess.get("SHARED_STORAGE");
            the = (sharedDir.length && ss.isList && ss.length > 0) ? sharedDir : dir;
            if (the !is null && !the.endsWith("/"))
                the ~= "/";
        }
        auto path = kw.get("path").isNone ? throw new Exception("getfolder() missing path") : kw["path"].toString;
        return listFilesystem(the, path, td, kw.get("file_type", Value("")), kw.get("show_hidden").truthy, result);
    }

    void checkAccess(string ss)
    {
        if (sharedDir.length)
        {
            auto sdirs = ConfigAccess.get("SHARED_STORAGE");
            if (sdirs.isList)
                foreach (sd; sdirs.list.items)
                    if (sd["name"] == Value(ss) && sd.get("restricted_access").truthy && !currentUserHasRole("Administrator"))
                        throw new PermissionError(ACCESS_DENIED_MESSAGE);
        }
    }
}

final class FileManagerModule : Blueprint
{
    this()
    {
        super("file_manager");
        staticDir("misc/file_manager");
    }

    override string[] getExposedUrlEndpoints() => ["file_manager.init", "file_manager.filemanager", "file_manager.index",
        "file_manager.delete_trans_id", "file_manager.save_last_dir", "file_manager.save_file_dialog_view",
        "file_manager.save_show_hidden_file_option", "file_manager.load_file", "file_manager.save_file"];

    override Value getOwnMenuItems() => Value.dictOf("file_items", Value.newList());

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        route("/init", "init", ["POST"], loginRequired((Dict a) => initFilemanager()));
        route("/delete_trans_id/<int:trans_id>", "delete_trans_id", ["DELETE"], loginRequired((Dict a) {
            Filemanager.releaseTransaction(a["trans_id"].toString);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", true));
        }));
        route("/save_last_dir/<int:trans_id>", "save_last_dir", ["POST"], loginRequired((Dict a) {
            auto j = parseJson(request().text);
            fmPrefSet("last_directory_visited", j["path"]);
            fmPrefSet("last_storage", j["storage_folder"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(null), 200);
        }));
        route("/save_file_dialog_view/<int:trans_id>", "save_file_dialog_view", ["POST"], loginRequired((Dict a) {
            auto j = parseJson(request().text);
            fmPrefSet("file_dialog_view", j["view"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(null), 200);
        }));
        route("/save_show_hidden_file_option/<int:trans_id>", "save_show_hidden_file_option", ["PUT"], loginRequired((Dict a) {
            auto j = parseJson(request().text);
            fmPrefSet("show_hidden_files", j["show_hidden"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(null), 200);
        }));
        route("/load_file/", "load_file", ["PUT", "POST"], loginRequired((Dict a) => loadFile()));
        route("/save_file/", "save_file", ["PUT", "POST"], loginRequired((Dict a) => saveFile()));
        route("/filemanager/<int:trans_id>/", "filemanager", ["POST"], loginRequired((Dict a) => fileManager(a)));
    }

    private static Response initFilemanager()
    {
        auto req = request();
        if (req.data.length == 0)
            throw new Exception("local variable 'res_data' referenced before assignment");
        auto configs = parseJson(req.text);
        auto transId = Filemanager.createNewTransaction(configs);
        auto data = Filemanager.getTransactionSelection(transId);
        auto fileDialogView = fmPref("file_dialog_view");
        if (fileDialogView.isList)
            fileDialogView = fileDialogView[0];
        auto lastSelected = getFileTypeSetting(data["supported_types"]);
        if (!data["supported_types"].contains(lastSelected))
            lastSelected = data["supported_types"][0];
        auto resData = Value.dictOf("transId", transId, "options", Value.dictOf("culture", "en", "lang", "py", "defaultViewMode",
                fileDialogView, "autoload", true, "showFullPath", false, "dialog_type", data["dialog_type"],
                "show_hidden_files", fmPref("show_hidden_files"), "fileRoot", data["fileroot"], "capabilities",
                data["capabilities"], "allowed_file_types", data["supported_types"], "platform_type", data["platform_type"],
                "show_volumes", data["show_volumes"], "homedir", data["homedir"], "storage_folder", data["storage_folder"],
                "last_selected_format", lastSelected), "security", Value.dictOf("uploadPolicy",
                data["security"]["uploadPolicy"], "uploadRestrictions", data["security"]["uploadRestrictions"]), "upload",
                Value.dictOf("multiple", data["upload"]["multiple"], "number", 20, "fileSizeLimit",
                data["upload"]["fileSizeLimit"], "imagesOnly", false));
        return makeJsonResponse(1, Value(""), Value(""), Value(null), resData);
    }

    private static Value getFileTypeSetting(Value fileTypes)
    {
        string dialogType;
        bool has(string t) => fileTypes.contains(Value(t));
        if (has("pgerd"))
            dialogType = "erd_file_type";
        else if (has("backup"))
            dialogType = "backup_file_type";
        else if (has("csv") && has("txt"))
            dialogType = "import_export_file_type";
        else if (has("csv") && !has("txt"))
            dialogType = "storage_manager_file_type";
        else
            dialogType = "sqleditor_file_format";
        auto row = db.queryOne("SELECT value FROM setting WHERE user_id = ? AND setting = ?", Value(currentUserId()), Value(dialogType));
        return row.isNone ? Value("*") : row["value"];
    }

    private static Response loadFile()
    {
        auto fileData = parseJson(request().text);
        auto filePath = unquote(fileData["file_name"].toString);
        string storageFolder = fileData.contains("storage") ? fileData["storage"].toString : fmPref("last_storage").toString;
        auto storageDir = getStorageDirectory(storageFolder);
        try
            checkAccessPermission(storageDir, filePath);
        catch (Exception e)
            return internalServerError(e.msg);
        if (storageDir !is null)
        {
            while (filePath.length && (filePath[0] == '/' || filePath[0] == '\\'))
                filePath = filePath[1 .. $];
            filePath = buildPath(storageDir, filePath);
        }
        bool isBinary;
        string enc = "utf-8";
        try
        {
            auto data = cast(ubyte[]) read(filePath, 1024);
            bool bom = data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF;
            if (bom)
                enc = "utf-8-sig";
            else if (data.length >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF)))
            {
                bom = true;
                enc = "utf-16";
            }
            if (!bom)
                foreach (b; data)
                    if (!(b == 7 || b == 8 || b == 9 || b == 10 || b == 12 || b == 13 || b == 27 || (b >= 0x20 && b < 0x7f) || b >= 0x80))
                    {
                        isBinary = true;
                        break;
                    }
            loadedEncodings[baseName(filePath)] = enc;
        }
        catch (Exception e)
            throw new Exception("cannot unpack non-iterable Response object");
        if (isBinary)
            return internalServerError(gettext("File type not supported"));
        auto content = cast(string) read(filePath);
        if (content.length >= 3 && content[0 .. 3] == "\xEF\xBB\xBF")
            content = content[3 .. $];
        return new Response(content, 200, "text/plain");
    }

    private static Response saveFile()
    {
        auto fileData = parseJson(request().text);
        auto lastStorage = fmPref("last_storage").toString;
        string storageDir;
        if (lastStorage != MY_STORAGE)
            storageDir = getStorageDirectory(lastStorage);
        else
            storageDir = getStorageDirectory();
        auto filePath = unquote(fileData["file_name"].toString);
        try
            checkAccessPermission(storageDir, filePath);
        catch (Exception e)
            return internalServerError(e.msg);
        if (storageDir !is null)
        {
            while (filePath.length && (filePath[0] == '/' || filePath[0] == '\\'))
                filePath = filePath[1 .. $];
            filePath = buildPath(storageDir, filePath);
        }
        try
            write(filePath, fileData["file_content"].toString);
        catch (Exception e)
            return internalServerError("Error: " ~ e.msg);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", true));
    }

    private static Response fileManager(Dict a)
    {
        auto transId = a["trans_id"].toString;
        auto req = request();
        Value kw = Value.newDict();
        string mode;
        if (req.files.length)
        {
            mode = "add";
            kw["storage_folder"] = Value(req.form.get("storage_folder"));
        }
        else
        {
            kw = parseJson(req.text);
            mode = kw["mode"].toString;
            kw.dict.remove("mode");
        }
        string ss = kw.contains("storage_folder") && kw["storage_folder"].truthy ? kw["storage_folder"].toString : null;
        auto fm = new Filemanager(transId, ss is null ? "" : ss);
        if (ss.length && ["upload", "rename", "delete", "addfolder", "add", "permission"].canFind(mode))
        {
            try
                fm.checkAccess(ss);
            catch (PermissionError e)
                return unauthorizedMsg(e.msg);
        }
        kw.dict.remove("req");
        kw.dict.remove("storage_folder");
        Value result;
        try
        {
            switch (mode)
            {
            case "getfolder":
            {
                kw.dict.remove("name");
                auto err = fm.getfolder(kw, result);
                if (err !is null)
                    return err;
                break;
            }
            case "rename":
            {
                if (!fm.validateRequest("rename"))
                    return unauthorizedMsg(gettext("Not allowed"));
                auto the = fm.theDir();
                auto old = kw["old"].toString;
                auto new_ = kw["new"].toString;
                checkAccessPermission(the, old);
                checkAccessPermission(the, new_);
                if (old.endsWith("/"))
                    old = old[0 .. $ - 1];
                auto oldname = baseName(old);
                auto path = dirName(old);
                if (!path.endsWith("/"))
                    path ~= "/";
                auto newpath = path ~ new_;
                try
                    rename(the ~ old, the ~ newpath);
                catch (Exception e)
                    return internalServerError(gettext("There was an error renaming the file:") ~ " " ~ e.msg);
                result = Value.dictOf("Old Path", old, "Old Name", oldname, "New Path", newpath, "New Name", new_);
                break;
            }
            case "delete":
            {
                if (!fm.validateRequest("delete"))
                    return unauthorizedMsg(gettext("Not allowed"));
                auto the = fm.theDir();
                auto path = kw["path"].toString;
                auto orig = the ~ path;
                checkAccessPermission(the, path);
                try
                {
                    if (isDir(orig))
                        rmdir(orig);
                    else
                        remove(orig);
                }
                catch (Exception e)
                    return internalServerError(gettext("There was an error deleting the file:") ~ " " ~ e.msg);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(null), 200);
            }
            case "addfolder":
            {
                if (!fm.validateRequest("create"))
                    return unauthorizedMsg(gettext("Not allowed"));
                auto userDir = fm.theDir();
                auto path = kw["path"].toString;
                auto name = kw["name"].toString;
                checkAccessPermission(userDir, path ~ name);
                string newName = name;
                long count;
                string createPath, newPath;
                for (;;)
                {
                    if (!(path.endsWith("/") || name.startsWith("/")))
                        path ~= "/";
                    newPath = path ~ newName ~ "/";
                    createPath = userDir.length ? userDir ~ "/" ~ newPath : newPath;
                    if (!exists(createPath))
                        break;
                    count++;
                    newName = name ~ "_" ~ to!string(count);
                }
                try
                    mkdir(createPath);
                catch (Exception e)
                    return internalServerError(e.msg);
                result = Value.dictOf("Parent", path, "Path", newPath, "Name", newName, "Date Modified", ctime(Clock.currTime()));
                break;
            }
            case "is_file_exist":
            {
                auto the = fm.dir !is null ? fm.dir : "";
                auto name = unquote(kw["name"].toString);
                auto path = unquote(kw["path"].toString);
                checkAccessPermission(the, path ~ name);
                result = Value.dictOf("Path", path, "Name", name, "Code", exists(the ~ path ~ name) ? 1 : 0);
                break;
            }
            case "permission":
            {
                auto the = fm.dir !is null ? fm.dir : "";
                checkAccessPermission(the, kw["path"].toString);
                result = Value.dictOf("Code", 1);
                break;
            }
            case "download":
            {
                if (!fm.validateRequest("download"))
                    return unauthorizedMsg(gettext("Not allowed"));
                auto the = fm.theDir();
                auto path = kw["path"].toString;
                auto orig = the ~ path;
                checkAccessPermission(the, path ~ path);
                auto r = sendFile(orig);
                r.headers ~= ["Content-Disposition", "attachment; filename=" ~ baseName(path)];
                r.headers ~= ["filename", baseName(path)];
                r.mimetype = "application/octet-stream";
                return r;
            }
            case "add":
            {
                if (!fm.validateRequest("upload"))
                    return unauthorizedMsg(gettext("Not allowed"));
                auto the = fm.theDir();
                auto path = req.form.get("currentpath");
                auto fileObj = req.files["newfile"][0];
                auto newName = the ~ path ~ fileObj.filename;
                try
                    write(newName, fileObj.data);
                catch (Exception e)
                    return internalServerError(gettext("There was an error adding the file:") ~ " " ~ e.msg);
                result = Value.dictOf("Path", path, "Name", newName);
                break;
            }
            default:
                throw new Exception("'Filemanager' object has no attribute '" ~ mode ~ "'");
            }
        }
        catch (PermissionError e)
            return unauthorizedMsg(e.msg);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("result", result, "status", true));
    }
}

private __gshared string[string] loadedEncodings;
