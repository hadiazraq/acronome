#!/usr/bin/env python3
"""Download and build Acronome's third-party data layers.

  python3 scripts/fetch_data.py           # build Resources/data/adam.json (MEDLINE layer) if missing
  python3 scripts/fetch_data.py --force   # rebuild it even if it exists
  python3 scripts/fetch_data.py --hgnc    # also refresh Resources/data/hgnc.json from HGNC

MEDLINE layer: ADAM — Zhou, Torvik & Smalheiser (2006), Bioinformatics 22(22), 2813–2818,
https://doi.org/10.1093/bioinformatics/btl480. ADAM is distributed under the GNU GPL, so it is NOT
included in this repository: this script downloads it from the Medical Abbreviation and Acronym
Meta-Inventory (Grossman Liu et al., 2021, https://doi.org/10.1038/s41597-021-00929-4), pinned to one
commit and checked against a SHA-256 hash, and converts it locally on your machine.

Gene layer: HGNC complete set (CC0), already included; --hgnc refreshes it.
Only the Python standard library is used.
"""
import argparse, collections, csv, hashlib, io, json, re, sys, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "Resources" / "data"

ADAM_URL = ("https://raw.githubusercontent.com/lisavirginia/clinical-abbreviations/"
            "c2530a6519ec02246a4f577bf073e4dfe9428518/sources/2-adam/adam_database")
ADAM_SHA256 = "c75b7c5f7d8b886bb4acd21ee11e9e040c82016d96644751f36bce9130dc5610"
HGNC_URL = "https://storage.googleapis.com/public-download-files/hgnc/tsv/tsv/hgnc_complete_set.txt"

MIN_COUNT = 10      # keep pairs defined at least this often in MEDLINE
MIN_SCORE = 0.3     # ADAM phrase score

# Keyword field classifier: a heuristic, shown in the app as a guess.
FIELDS = [
 ("gen", r"\b(gene|genes|genom|genotyp|allele|chromosom|locus|loci|mutation|mutant|polymorphism|snp|haplotyp|heritab|linkage|exon|intron|transgen|knockout|knock-out|heterozyg|homozyg|epigen|methylation|crispr|sequencing|transcriptom|copy number|quantitative trait|mendelian|syndrome x-linked|imprinting)"),
 ("mol", r"(protein|kinase|phosphatase|receptor|ligand|enzyme|(?<!dise)ases?\b|synthase|transferase|reductase|oxidase|dehydrogenase|factor|peptide|amino acid|nucleotide|rna\b|dna\b|mrna|microrna|ribonucle|deoxyribo|transcription|translation|promoter|binding|domain|acid\b|ubiquitin|histone|chaperone|phospho|glyco|lipoprotein|cyclic|camp|adenosine|guanosine|coenzyme|nad|atp|gtp|oxygen species|radical|oxide|hormone|binding protein)"),
 ("cell", r"(cell|cells|cellular|mitochond|apoptos|autophag|cytoskelet|membrane|vesicle|organelle|endoplasmic|golgi|lysosom|stem|progenitor|fibroblast|epitheli|endotheli|differentiation|proliferation|cycle|mitosis|meiosis|matrix|adhesion|junction|cilia|nucleus|nuclear)"),
 ("neuro", r"(neur|brain|cortex|cortical|hippocamp|synap|axon|dendrit|glia|astrocyt|microglia|oligodendro|spinal|cerebr|cerebell|thalam|striat|amygdal|dopamin|serotonin|glutamat|gaba|acetylcholin|cholinergic|potentiation|depression\b(?!.*major)|nerve|ganglion|ganglia|nucleus accumbens|parkinson|alzheimer|huntington|multiple sclerosis|epilep|schizophren|autism|adhd|attention-deficit|dementia|seizure|nociceptor|retina|photoreceptor|rod outer|cone|olfactory|auditory|vestibul|cognit|memory|evoked potential)"),
 ("imm", r"(immun|antibod|antigen|t cell|b cell|t-cell|b-cell|lymph|leukocyt|macrophage|neutrophil|monocyt|dendritic|natural killer|interleukin|interferon|cytokine|chemokine|complement|tumor necrosis|tumour necrosis|histocompat|hla\b|mhc|toll-like|inflamm|allerg|\big[egma]\b|autoimmun|vaccin|thymus|spleen)"),
 ("micro", r"(virus|viral|vir\b|bacteri|bacillus|coccus|fung|yeast|parasit|plasmodium|microb|phage|pathogen|infect|hiv|hepatitis|influenza|herpes|cytomegalo|epstein|coli\b|salmonella|staphylococ|streptococ|mycobact|tuberculosis|antibiotic|resistan)"),
 ("pharm", r"(drug|pharmac|inhibitor|agonist|antagonist|blocker|dose|dosage|toxic|metaboli[ts]e|clearance|bioavailab|pharmacokinet|pharmacodynam|therapeutic|anticonvuls|antidepress|antipsychot|analges|anesthe|anaesthe|statin|nsaid|chemotherap)"),
 ("phys", r"(blood|plasma|serum|pressure|heart|cardiac|vascular|arter|ven(ous|a)\b|renal|kidney|liver|hepat|lung|pulmonar|respirat|muscle|muscul|bone|skelet|endocrin|insulin|glucose|thyroid|adrenal|pituitar|gastr|intestin|pancrea|metabolic rate|oxygen consumption|heart rate|body mass|potential difference|ventric|atri(al|um))"),
 ("meth", r"(assay|electrophoresis|chromatograph|spectrometr|spectroscop|blot|polymerase chain|pcr|elisa|immunohisto|immunofluor|flow cytometr|microscop|staining|stain\b|hybridization|cloning|culture|centrifug|transfection|in situ|immunoprecip|sequenc|microarray|labeling|labelling|fluorescen|resonance energy)"),
 ("img", r"(imaging|tomograph|magnetic resonance|mri|fmri|ultrasound|ultrason|doppler|radiograph|x-ray|positron|emission|electroencephal|electromyograph|electrocardiograph|magnetoenceph|diffusion tensor|bold|event-related potential|evoked|spectroscopic imaging|scan\b)"),
 ("stat", r"(analysis|regression|variance|statistic|correlation|coefficient|confidence interval|odds ratio|ratio\b|probability|likelihood|bayes|model\b|algorithm|principal component|independent component|standard deviation|standard error|mean\b|quantification|recurrence|fractal|entropy|bioinformat|database|ontology)"),
 ("clin", r"(itis\b|osis\b|emia\b|aemia\b|oma\b|pathy\b|disease|syndrome|disorder|patient|clinical|surgery|surgical|carcinoma|cancer|tumor|tumour|leukemia|leukaemia|lymphoma|sarcoma|diabetes|hypertension|failure|infarction|stroke|therapy|treatment|trial|diagnos|score\b|scale\b|index\b|questionnaire|transplant|dialysis|ectomy\b|otomy\b|plasty\b|ostomy\b|care unit|emergency)"),
 ("dent", r"(dental|tooth|teeth|periodont|gingiv|caries|enamel|dentin|pulp\b|orthodont|endodont|maxill|mandib|oral\b|occlus|probing|alveolar bone|implant|denture|molar|incisor|saliva)"),
 ("eco", r"(species|evolution|phylogen|ecolog|population|habitat|plant|leaf|root|seed|photosynth|chlorophyll|insect|fish|bird|marine|soil|forest|biodivers|arabidopsis|drosophila|zebrafish|elegans)"),
 ("chem", r"(methyl|ethyl|phenyl|benz|amine|amide|ester|chlor|fluor|bromo|nitro|hydroxy|carbox|sulf|phosph(?!at)|oxo|acetyl|propyl|butyl|-yl\b|ol\b|one\b|ate\b|ide\b)"),
]
FRX = [(f, re.compile(rx, re.I)) for f, rx in FIELDS]

def classify(lf):
    tags = [f for f, rx in FRX if rx.search(lf)]
    # chem is a weak signal; drop if anything else matched
    if len(tags) > 1 and "chem" in tags:
        tags.remove("chem")
    return tags[:2] if tags else ["gen_bio"]



def download(url):
    print(f"  downloading {url.split('/')[-1]} …", flush=True)
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def lfkey(sf, lf):
    k = lf.lower().replace("ae", "e").replace("oe", "e").replace("our", "or").replace("-", " ")
    return sf + "|" + re.sub(r"s\b", "", k)


def build_adam(raw: bytes):
    rows = []
    for line in raw.decode("utf-8", errors="replace").splitlines():
        if line.startswith("#"):
            continue
        p = line.split("\t")
        if len(p) < 5:
            continue
        sf, variants, lfs, score, count = p[0], p[1], p[2], float(p[3]), int(p[4])
        if count < MIN_COUNT or score < MIN_SCORE:
            continue
        best = max((v.rsplit(":", 2) for v in lfs.split("|")),
                   key=lambda x: int(x[1]) if len(x) > 1 and x[1].isdigit() else 0)
        lf = best[0].strip()
        if len(lf) < 3 or lf.lower() == sf.lower():
            continue
        alts = sorted({v.rsplit(":", 1)[0] for v in variants.split("|")} - {sf})
        rows.append([sf, lf, classify(lf), count, alts[:4]])
    merged = {}
    for r in rows:
        k = lfkey(r[0], r[1])
        if k in merged:
            m = merged[k]
            keep, other = (r, m) if r[3] > m[3] else (m, r)
            keep[3] += other[3]
            keep[4] = sorted(set(keep[4]) | set(other[4]))[:4]
            merged[k] = keep
        else:
            merged[k] = r
    return list(merged.values())


def build_hgnc(raw: bytes):
    out = []
    for r in csv.DictReader(io.StringIO(raw.decode("utf-8")), delimiter="\t"):
        if r["status"] != "Approved":
            continue
        lg, lt = r["locus_group"], r["locus_type"]
        if lg == "protein-coding gene":
            kind = "pc"
        elif lt in ("RNA, micro", "RNA, transfer", "RNA, ribosomal", "RNA, small nucleolar", "RNA, small nuclear"):
            kind = "nc"
        elif (lt == "RNA, long non-coding" and not r["name"].startswith(("long intergenic", "uncharacterized"))
              and not re.match(r"^(LINC|LOC)\d", r["symbol"])):
            kind = "nc"
        else:
            continue
        if r["name"].startswith("uncharacterized"):
            continue
        aliases = [a for a in (r["alias_symbol"] + "|" + r["prev_symbol"]).replace('"', "").split("|") if a][:6]
        out.append([r["symbol"], r["name"], kind, r["location"], r["hgnc_id"].replace("HGNC:", ""),
                    r["entrez_id"], aliases, (r["gene_group"] or "").replace('"', "").split("|")[0]])
    return out


def write(name, rows):
    DATA.mkdir(parents=True, exist_ok=True)
    (DATA / name).write_text(json.dumps(rows, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"  wrote Resources/data/{name} ({len(rows):,} entries)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true", help="rebuild adam.json even if it exists")
    ap.add_argument("--hgnc", action="store_true", help="also refresh hgnc.json from HGNC")
    ap.add_argument("--adam-file", help="use a local copy of adam_database instead of downloading")
    a = ap.parse_args()

    if a.force or a.adam_file or not (DATA / "adam.json").exists():
        print("MEDLINE layer (ADAM, GPL — downloaded, not redistributed):")
        raw = Path(a.adam_file).read_bytes() if a.adam_file else download(ADAM_URL)
        digest = hashlib.sha256(raw).hexdigest()
        if digest != ADAM_SHA256:
            sys.exit(f"  checksum mismatch ({digest}); refusing to build from an unexpected file")
        rows = build_adam(raw)
        write("adam.json", rows)
        print("  fields:", ", ".join(f"{k} {v}" for k, v in collections.Counter(t for r in rows for t in r[2]).most_common()))
    else:
        print("MEDLINE layer: Resources/data/adam.json already present (use --force to rebuild)")

    if a.hgnc:
        print("Gene layer (HGNC, CC0):")
        write("hgnc.json", build_hgnc(download(HGNC_URL)))


if __name__ == "__main__":
    main()
