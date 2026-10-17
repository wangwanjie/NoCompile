//
//  ExPlaylist.cpp
//  场景 M08：静态库里的 .cpp（成员函数、std::map、lambda、算法）
//

#include "ExPlaylist.hpp"
#include <algorithm>
#include <numeric>

void ExPlaylist::add(const std::string &track, int duration) {
    tracks_.push_back(track);
    durations_[track] = duration;
}

int ExPlaylist::totalDuration() const {
    return std::accumulate(durations_.begin(), durations_.end(), 0,
                           [](int sum, const std::pair<const std::string, int> &item) {
                               return sum + item.second;
                           });
}

std::string ExPlaylist::summary() const {
    std::vector<std::string> sorted = tracks_;
    std::sort(sorted.begin(), sorted.end());
    std::string result = "ExPlaylist(@@v1@@):";
    for (const auto &track : sorted) {
        result += track + ",";
    }
    result += std::to_string(totalDuration());
    return result;
}
