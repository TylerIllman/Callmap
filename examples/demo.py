"""A small module to try callmap.nvim on.

Put the cursor on `run_pipeline` and run :Callmap.
"""


def read_records(path):
    """Yield the raw lines of a data file."""
    with open(path) as handle:
        for line in handle:
            yield line.rstrip("\n")


def parse_record(line):
    """Split one line into a name and a sequence."""
    name, sequence = line.split("\t")
    return name, normalise(sequence)


def normalise(sequence):
    """Upper-case a sequence and turn T into U."""
    return sequence.upper().replace("T", "U")


def load_dataset(path):
    """Read every record in a file."""
    return [parse_record(line) for line in read_records(path)]


def score_pair(first, second):
    """Count the matching positions of two sequences."""
    return sum(a == b for a, b in zip(first, second))


def score_alignment(records):
    """Score every record against the first one."""
    reference = records[0][1]
    return {name: score_pair(reference, sequence) for name, sequence in records}


def summarise(scores):
    """Reduce the scores to a few numbers."""
    values = list(scores.values())
    return {"best": max(values), "worst": min(values), "mean": sum(values) / len(values)}


def format_table(summary):
    """Render a summary as aligned text."""
    return "\n".join(f"{key:<8}{value:>8.2f}" for key, value in summary.items())


def write_report(summary, out_path):
    """Write the summary table to a file."""
    with open(out_path, "w") as handle:
        handle.write(format_table(summary))


def run_pipeline(path, out_path):
    """Load, score, summarise and report on one data file."""
    records = load_dataset(path)
    scores = score_alignment(records)
    summary = summarise(scores)
    write_report(summary, out_path)
    return summary


def main():
    """Run the pipeline on the default files."""
    return run_pipeline("data.tsv", "report.txt")


def cli():
    """Entry point used by the command line."""
    main()


def benchmark():
    """Time the pipeline over several files."""
    return [run_pipeline(f"data_{i}.tsv", f"report_{i}.txt") for i in range(3)]


def test_pipeline():
    """Check that the pipeline returns a summary."""
    assert "best" in run_pipeline("data.tsv", "report.txt")
