/// `databases/dbms_job_scheduler/utils`: DBMS Job Scheduler utilities.
module pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler.utils;

import std.algorithm : canFind;
import std.array : join, split;
import std.conv : to;
import std.string : strip, toUpper, indexOf;
import pgadmin.core.value;

immutable string[string] MONTHS_MAPPING = [
    "JAN": "1", "FEB": "2", "MAR": "3", "APR": "4", "MAY": "5", "JUN": "6",
    "JUL": "7", "AUG": "8", "SEP": "9", "OCT": "10", "NOV": "11", "DEC": "12"
];

immutable string[string] WEEKDAY_MAPPING = [
    "MON": "1", "TUE": "2", "WED": "3", "THU": "4", "FRI": "5", "SAT": "6", "SUN": "7"
];

immutable string[string] MONTHS_MAPPING_REV = [
    "1": "JAN", "2": "FEB", "3": "MAR", "4": "APR", "5": "MAY", "6": "JUN",
    "7": "JUL", "8": "AUG", "9": "SEP", "10": "OCT", "11": "NOV", "12": "DEC"
];

immutable string[string] WEEKDAY_MAPPING_REV = [
    "1": "MON", "2": "TUE", "3": "WED", "4": "THU", "5": "FRI", "6": "SAT", "7": "SUN"
];

struct CalendarData
{
    string freq;
    string byDate;
    string[] byMonth;
    string[] byMonthday;
    string[] byWeekday;
    string[] byHour;
    string[] byMinute;
}

CalendarData resolveCalendarString(string calStr)
{
    CalendarData res;
    if (calStr.length == 0)
        return res;

    auto tokens = calStr.split(";");
    foreach (tok; tokens)
    {
        tok = tok.strip();
        if (tok.length == 0)
            continue;
        auto eqIdx = tok.indexOf("=");
        if (eqIdx == -1)
            continue;
        auto name = tok[0 .. eqIdx].strip().toUpper();
        auto val = tok[eqIdx + 1 .. $].strip();

        switch (name)
        {
        case "FREQ":
            res.freq = val;
            break;
        case "BYDATE":
            res.byDate = val;
            break;
        case "BYMONTH":
            foreach (v; val.split(","))
            {
                auto vu = v.toUpper();
                if (vu in MONTHS_MAPPING)
                    res.byMonth ~= MONTHS_MAPPING[vu];
                else
                    res.byMonth ~= v;
            }
            break;
        case "BYMONTHDAY":
            res.byMonthday = val.split(",");
            break;
        case "BYDAY":
            foreach (v; val.split(","))
            {
                auto vu = v.toUpper();
                if (vu in WEEKDAY_MAPPING)
                    res.byWeekday ~= WEEKDAY_MAPPING[vu];
                else
                    res.byWeekday ~= v;
            }
            break;
        case "BYHOUR":
            res.byHour = val.split(",");
            break;
        case "BYMINUTE":
            res.byMinute = val.split(",");
            break;
        default:
            break;
        }
    }
    return res;
}

string createCalendarString(string freq, string date, string[] months, string[] monthdays,
        string[] weekdays, string[] hours, string[] minutes)
{
    string res;
    if (freq.length > 0)
        res ~= "FREQ=" ~ freq ~ ";";
    if (date.length > 0)
        res ~= "BYDATE=" ~ date ~ ";";
    if (months.length > 0)
    {
        string[] revMonths;
        foreach (m; months)
        {
            if (m in MONTHS_MAPPING_REV)
                revMonths ~= MONTHS_MAPPING_REV[m];
            else
                revMonths ~= m;
        }
        res ~= "BYMONTH=" ~ revMonths.join(",") ~ ";";
    }
    if (monthdays.length > 0)
        res ~= "BYMONTHDAY=" ~ monthdays.join(",") ~ ";";
    if (weekdays.length > 0)
    {
        string[] revWeekdays;
        foreach (w; weekdays)
        {
            if (w in WEEKDAY_MAPPING_REV)
                revWeekdays ~= WEEKDAY_MAPPING_REV[w];
            else
                revWeekdays ~= w;
        }
        res ~= "BYDAY=" ~ revWeekdays.join(",") ~ ";";
    }
    if (hours.length > 0)
        res ~= "BYHOUR=" ~ hours.join(",") ~ ";";
    if (minutes.length > 0)
        res ~= "BYMINUTE=" ~ minutes.join(",");
    return res;
}
