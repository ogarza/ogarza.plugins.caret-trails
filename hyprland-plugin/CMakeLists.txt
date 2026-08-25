cmake_minimum_required(VERSION 3.27)

project(caret-tracker
    DESCRIPTION "caret-tracker plugin for Hyprland"
    VERSION 1.0.0
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

file(GLOB_RECURSE SRC "src/*.cpp")

add_library(caret-tracker SHARED ${SRC})

find_package(PkgConfig REQUIRED)
pkg_check_modules(deps REQUIRED IMPORTED_TARGET
    hyprland
    wayland-server
)

find_package(Threads REQUIRED)

target_link_libraries(caret-tracker PRIVATE
    Threads::Threads
    PkgConfig::deps
)
