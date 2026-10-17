//
//  ExPlaylist.hpp
//

#ifndef ExPlaylist_hpp
#define ExPlaylist_hpp

#include <string>
#include <vector>
#include <map>

/// 非模板 C++ 类：成员函数在 ExPlaylist.cpp 实现（场景 B15）
class ExPlaylist {
public:
    void add(const std::string &track, int duration);
    std::string summary() const;
    int totalDuration() const;

private:
    std::vector<std::string> tracks_;
    std::map<std::string, int> durations_;
};

#endif /* ExPlaylist_hpp */
