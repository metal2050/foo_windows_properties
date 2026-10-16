#pragma once
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace wpetest {

struct Case {
    const char* name;
    std::function<void()> fn;
};

inline std::vector<Case>& registry() {
    static std::vector<Case> r;
    return r;
}
inline int& failures() {
    static int f = 0;
    return f;
}
inline int& checks() {
    static int c = 0;
    return c;
}

struct Registrar {
    Registrar(const char* n, std::function<void()> f) { registry().push_back({n, std::move(f)}); }
};

inline std::string show(const std::string& s) { return "\"" + s + "\""; }
inline std::string show(const char* s) { return show(std::string(s)); }
inline std::string show(bool b) { return b ? "true" : "false"; }
template <typename T>
std::string show(const T& v) {
    if constexpr (requires { v.begin(); v.end(); }) {
        std::string out = "[";
        bool first = true;
        for (auto& e : v) {
            if (!first) out += ", ";
            out += show(e);
            first = false;
        }
        return out + "]";
    } else {
        std::ostringstream os;
        os << v;
        return os.str();
    }
}

template <typename A, typename B>
void check_eq(const A& a, const B& b, const char* ea, const char* eb, const char* file, int line) {
    ++checks();
    if (!(a == b)) {
        ++failures();
        std::ostringstream os;
        os << show(a) << " vs " << show(b);
        std::fprintf(stderr, "%s:%d: CHECK_EQ(%s, %s) failed: %s\n", file, line, ea, eb, os.str().c_str());
    }
}

// WPE_TEST_ONLY=a,b runs only the tests whose names contain one of the comma-separated parts.
inline bool selected(const std::string& name) {
    const char* only = std::getenv("WPE_TEST_ONLY");
    if (!only || !*only) return true;
    std::string list = only;
    for (size_t start = 0; start <= list.size();) {
        size_t end = list.find(',', start);
        if (end == std::string::npos) end = list.size();
        const std::string part = list.substr(start, end - start);
        if (!part.empty() && name.find(part) != std::string::npos) return true;
        start = end + 1;
    }
    return false;
}

inline int run_all() {
    size_t ran = 0;
    for (auto& c : registry()) {
        if (!selected(c.name)) continue;
        const int before = failures();
        c.fn();
        ++ran;
        std::printf("%s %s\n", failures() == before ? "ok  " : "FAIL", c.name);
    }
    std::printf("%zu tests, %d checks, %d failures\n", ran, checks(), failures());
    return failures() ? 1 : 0;
}

}

#define WPE_CAT2(a, b) a##b
#define WPE_CAT(a, b) WPE_CAT2(a, b)
#define TEST(name)                                                                       \
    static void name();                                                                  \
    static wpetest::Registrar WPE_CAT(reg_, name)(#name, name);                          \
    static void name()
#define CHECK(cond)                                                                       \
    do {                                                                                  \
        ++wpetest::checks();                                                              \
        if (!(cond)) {                                                                    \
            ++wpetest::failures();                                                        \
            std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #cond); \
        }                                                                                 \
    } while (0)
#define CHECK_EQ(a, b) wpetest::check_eq((a), (b), #a, #b, __FILE__, __LINE__)
