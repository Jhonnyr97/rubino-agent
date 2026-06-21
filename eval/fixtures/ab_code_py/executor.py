"""A sizeable Python module: a toy task executor + helpers (control fixture).
Structurally parallel to the Ruby executor so the .py vs .rb code-compression
difference is visible: the code skeletoner is Ruby-only, so this passes through.
"""

import json
import time
from dataclasses import dataclass


class Handler0:
    """Handler number 0 — does some work."""
    def __init__(self, config):
        self.config = config
        self.calls = 0
    def method_0_0(self, arg):
        """Method 0 of handler 0."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 1 + 0
        return total

    def method_0_1(self, arg):
        """Method 1 of handler 0."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 1 + 1
        return total

    def method_0_2(self, arg):
        """Method 2 of handler 0."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 1 + 2
        return total

    def method_0_3(self, arg):
        """Method 3 of handler 0."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 1 + 3
        return total


class Handler1:
    """Handler number 1 — does some work."""
    def __init__(self, config):
        self.config = config
        self.calls = 0
    def method_1_0(self, arg):
        """Method 0 of handler 1."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 2 + 0
        return total

    def method_1_1(self, arg):
        """Method 1 of handler 1."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 2 + 1
        return total

    def method_1_2(self, arg):
        """Method 2 of handler 1."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 2 + 2
        return total

    def method_1_3(self, arg):
        """Method 3 of handler 1."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 2 + 3
        return total


class Handler2:
    """Handler number 2 — does some work."""
    def __init__(self, config):
        self.config = config
        self.calls = 0
    def method_2_0(self, arg):
        """Method 0 of handler 2."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 3 + 0
        return total

    def method_2_1(self, arg):
        """Method 1 of handler 2."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 3 + 1
        return total

    def method_2_2(self, arg):
        """Method 2 of handler 2."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 3 + 2
        return total

    def method_2_3(self, arg):
        """Method 3 of handler 2."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 3 + 3
        return total


class Handler3:
    """Handler number 3 — does some work."""
    def __init__(self, config):
        self.config = config
        self.calls = 0
    def method_3_0(self, arg):
        """Method 0 of handler 3."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 4 + 0
        return total

    def method_3_1(self, arg):
        """Method 1 of handler 3."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 4 + 1
        return total

    def method_3_2(self, arg):
        """Method 2 of handler 3."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 4 + 2
        return total

    def method_3_3(self, arg):
        """Method 3 of handler 3."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 4 + 3
        return total


class Handler4:
    """Handler number 4 — does some work."""
    def __init__(self, config):
        self.config = config
        self.calls = 0
    def method_4_0(self, arg):
        """Method 0 of handler 4."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 5 + 0
        return total

    def method_4_1(self, arg):
        """Method 1 of handler 4."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 5 + 1
        return total

    def method_4_2(self, arg):
        """Method 2 of handler 4."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 5 + 2
        return total

    def method_4_3(self, arg):
        """Method 3 of handler 4."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 5 + 3
        return total


class Handler5:
    """Handler number 5 — does some work."""
    def __init__(self, config):
        self.config = config
        self.calls = 0
    def method_5_0(self, arg):
        """Method 0 of handler 5."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 6 + 0
        return total

    def method_5_1(self, arg):
        """Method 1 of handler 5."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 6 + 1
        return total

    def method_5_2(self, arg):
        """Method 2 of handler 5."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 6 + 2
        return total

    def method_5_3(self, arg):
        """Method 3 of handler 5."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 6 + 3
        return total


class Handler6:
    """Handler number 6 — does some work."""
    def __init__(self, config):
        self.config = config
        self.calls = 0
    def method_6_0(self, arg):
        """Method 0 of handler 6."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 7 + 0
        return total

    def method_6_1(self, arg):
        """Method 1 of handler 6."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 7 + 1
        return total

    def method_6_2(self, arg):
        """Method 2 of handler 6."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 7 + 2
        return total

    def method_6_3(self, arg):
        """Method 3 of handler 6."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 7 + 3
        return total


class Handler7:
    """Handler number 7 — does some work."""
    def __init__(self, config):
        self.config = config
        self.calls = 0
    def method_7_0(self, arg):
        """Method 0 of handler 7."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 8 + 0
        return total

    def method_7_1(self, arg):
        """Method 1 of handler 7."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 8 + 1
        return total

    def method_7_2(self, arg):
        """Method 2 of handler 7."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 8 + 2
        return total

    def method_7_3(self, arg):
        """Method 3 of handler 7."""
        self.calls += 1
        total = 0
        for i in range(arg):
            total += i * 8 + 3
        return total


