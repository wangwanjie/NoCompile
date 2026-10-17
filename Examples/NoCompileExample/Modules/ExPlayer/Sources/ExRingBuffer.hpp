//
//  ExRingBuffer.hpp
//  头文件里的 C++ 模板：场景 H07（模板在每个引用方实例化，头文件变更要重编所有引用方）
//

#ifndef ExRingBuffer_hpp
#define ExRingBuffer_hpp

#include <vector>
#include <string>

template <typename T>
class ExRingBuffer {
public:
    explicit ExRingBuffer(size_t capacity) : data_(capacity), head_(0), size_(0) {}

    void push(const T &value) {
        data_[(head_ + size_) % data_.size()] = value;
        if (size_ < data_.size()) {
            size_ += 1;
        } else {
            head_ = (head_ + 1) % data_.size();
        }
    }

    size_t size() const {
        return size_;
    }

    T at(size_t index) const {
        return data_[(head_ + index) % data_.size()];
    }

    /// 带版本令牌的描述
    static std::string tag() {
        return "ExRingBuffer:@@v1@@";
    }

private:
    std::vector<T> data_;
    size_t head_;
    size_t size_;
};

#endif /* ExRingBuffer_hpp */
