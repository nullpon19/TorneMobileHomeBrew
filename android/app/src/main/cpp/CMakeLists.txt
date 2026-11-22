cmake_minimum_required(VERSION 3.22.1)

project(tmhb_fcntl C)

add_library(tmhb_fcntl SHARED tmhb_fcntl.c tmhb_aes.c)
target_compile_options(tmhb_fcntl PRIVATE -O3)
