import os
from argparse import ArgumentParser
from pathlib import Path

import pandas as pd

def nanoSummary(opts):
    """Produce summary file from NanoStats files"""
    # Read list of NanoStat file paths
    with open(opts.input, "r") as f:
        f_paths = f.readlines()

    # Set up empty df to store run data
    run_metrics = pd.DataFrame()

    # Main loop to extract data from each NanoStat file and merge into a single dataframe
    for pth in f_paths:
        pth = Path(pth.strip())

        # Extract sample name from file path
        s_name = os.path.basename(pth)
        s_name = str(s_name).removesuffix("NanoStats.txt")

        # Read relevant data from file into pandas dataframe
        data = pd.read_table(pth, sep=":\s+", skiprows=1, nrows=12, names=['metric', s_name],
                             index_col=0)
        if run_metrics.empty:
            run_metrics = data
        else:
            run_metrics = pd.merge(run_metrics, data, on='metric')

    run_metrics = run_metrics.transpose()

    run_metrics.to_csv("QC_Summary.csv")


if __name__ == "__main__":
    parser = ArgumentParser(description='Script to summarise NanoPlot QC results')
    parser.add_argument('-i',
                        '--input',
                        required=True,
                        #type=Path,
                        help="Path to file containing a list of paths to NanoPlot 'NanoStats' output.")
    parser.add_argument('-o',
                        '--output',
                        default='summary_output.txt',
                        help="Name of output file. Default = 'summary_output.txt'")
    opts = parser.parse_args()
    nanoSummary(opts)