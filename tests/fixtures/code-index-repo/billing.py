"""Tiny fixture for the code-index image test: one call edge to find."""


def compute_invoice_total(lines):
    return sum(apply_line_discount(line) for line in lines)


def apply_line_discount(line):
    return line["amount"] * (1 - line.get("discount", 0))
