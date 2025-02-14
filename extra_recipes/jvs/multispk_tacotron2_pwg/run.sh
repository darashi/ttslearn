#!/bin/bash

set -e
set -u
set -o pipefail

function xrun () {
    set -x
    $@
    set +x
}

script_dir=$(cd $(dirname ${BASH_SOURCE:-$0}); pwd)
COMMON_ROOT=../../../recipes/common
. $COMMON_ROOT/yaml_parser.sh || exit 1;

eval $(parse_yaml "./config.yaml" "")

train_set="train"
dev_set="dev"
eval_set="eval"
datasets=($train_set $dev_set $eval_set)
testsets=($eval_set)

stage=0
stop_stage=0

. $COMMON_ROOT/parse_options.sh || exit 1;

dumpdir=dump
dump_org_dir=$dumpdir/jvs001-100_sr${sample_rate}/org
dump_norm_dir=$dumpdir/jvs001-100_sr${sample_rate}/norm

vocoder_model=$(basename $parallel_wavegan_config)
vocoder_model=${vocoder_model%.*}

# exp name
if [ -z ${tag:=} ]; then
    expname=jvs001-100_sr${sample_rate}
else
    expname=jvs001-100_sr${sample_rate}_${tag}
fi
expdir=exp/$expname

if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    echo "stage -1: Data download"
    mkdir -p downloads

    echo "Please download data manually!"
    echo "JVS corpus: https://sites.google.com/site/shinnosuketakamichi/research-topics/jvs_corpus"
    echo "After downloading the corpus, please run audio.sh from https://github.com/r9y9/jvs_r9y9"
    echo "to remove some wrong/missing-label utterances."
    echo "Please make sure to have JVS corpus in 'db_root' in config.yaml."
    exit 1
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    echo "stage 0: Data preparation"
    echo "train/dev/eval split"

    # NOTE: For, jvs006, jvs028, jvs037 (??), label files are missing.
    # these speakers are exlucded.
    for spk in $(cat data/spks); do
        echo $spk
        mkdir -p data/$spk/parallel100/
        find $db_root/$spk/parallel100/wav24kHz16bit/ -type f -name "*.wav" -exec basename {} \; | sed -e 's/.wav//' | sort > data/$spk/parallel100/utt_list.txt

        head -n 90 data/$spk/parallel100/utt_list.txt > data/$spk/parallel100/train.list
        tail -10 data/$spk/parallel100/utt_list.txt > data/$spk/parallel100/deveval.list
        head -n 5 data/$spk/parallel100/deveval.list > data/$spk/parallel100/dev.list
        tail -n 5 data/$spk/parallel100/deveval.list > data/$spk/parallel100/eval.list
        rm -f data/$spk/parallel100/deveval.list

        mkdir -p data/$spk/nonpara30/
        find $db_root/$spk/nonpara30/wav24kHz16bit/ -type f -name "*.wav" -exec basename {} \; | sed -e 's/.wav//' | sort > data/$spk/nonpara30/utt_list.txt

        head -n 28 data/$spk/nonpara30/utt_list.txt > data/$spk/nonpara30/train.list
        tail -2 data/$spk/nonpara30/utt_list.txt > data/$spk/nonpara30/deveval.list
        head -n 1 data/$spk/nonpara30/deveval.list > data/$spk/nonpara30/dev.list
        tail -n 1 data/$spk/nonpara30/deveval.list > data/$spk/nonpara30/eval.list
        rm -f data/$spk/nonpara30/deveval.list

        rm -f data/$spk/train.list data/$spk/dev.list data/$spk/eval.list
        for typ in parallel100 nonpara30; do
            cat data/$spk/$typ/train.list >> data/$spk/train.list
            cat data/$spk/$typ/dev.list >> data/$spk/dev.list
            cat data/$spk/$typ/eval.list >> data/$spk/eval.list
        done
    done

    # すべてまとめる
    rm -f data/train.list data/dev.list data/eval.list
    for spk in $(cat data/spks); do
        cat data/$spk/train.list >> data/train.list
        cat data/$spk/dev.list >> data/dev.list
        cat data/$spk/eval.list >> data/eval.list
    done
fi

if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    echo "stage 1: Feature generation"
    for spk in $(cat data/spks); do
        spk_id=$(cat data/spk2id | grep $spk | cut -f 2 -d":")
        echo $spk $spk_id
        for typ in parallel100 nonpara30; do
            for s in ${datasets[@]}; do
                xrun python preprocess.py data/$spk/$typ/$s.list $spk_id \
                $db_root/$spk/$typ/wav24kHz16bit --sample_rate $sample_rate \
                $db_root/${spk}/$typ/lab/ful/ $dump_org_dir/$s --n_jobs $n_jobs
            done
        done
    done
fi

if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    echo "stage 2: feature normalization"

    # NOTE: JVSコーパスは話者毎のデータ量が少ないので、JSUTコーパスで計算した統計量をベースに利用する
    xrun python $COMMON_ROOT/fit_scaler.py data/train.list \
        $dump_org_dir/$train_set/out_tacotron/ \
        $dump_org_dir/out_tacotron_scaler.joblib \
        --external_scaler $PWD/../../jsut/tacotron2_pwg/dump/jsut_sr${sample_rate}/org/out_tacotron_scaler.joblib

    mkdir -p $dump_norm_dir
    cp -v $dump_org_dir/*.joblib $dump_norm_dir/

    for s in ${datasets[@]}; do
        xrun python $COMMON_ROOT/preprocess_normalize.py data/$s.list \
            $dump_org_dir/out_tacotron_scaler.joblib \
            $dump_org_dir/$s/out_tacotron/ \
            $dump_norm_dir/$s/out_tacotron/ --n_jobs $n_jobs
        # 波形データは手動でコピー
        find $dump_org_dir/$s/out_tacotron/ -name "*-wave.npy" -exec cp "{}" $dump_norm_dir/$s/out_tacotron \;
        # 韻律記号付き音素列は手動でコピー
        rm -rf $dump_norm_dir/$s/in_tacotron
        cp -r $dump_org_dir/$s/in_tacotron $dump_norm_dir/$s/
    done
fi

if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    echo "stage 3: Training Tacotron"
    if [ -z ${pretrained_acoustic_checkpoint} ]; then
        pretrained_acoustic_checkpoint=$PWD/../../jsut/tacotron2_pwg/exp/jsut_sr${sample_rate}/${acoustic_model}/${acoustic_eval_checkpoint}
        if [ ! -e $pretrained_acoustic_checkpoint ]; then
            echo "Please first train a acoustic model for JSUT corpus!"
            echo "Expected model path: $pretrained_acoustic_checkpoint"
            exit 1
        fi
    fi
    xrun python train_tacotron.py model=$acoustic_model tqdm=$tqdm \
        data.train.utt_list=data/train.list \
        data.train.in_dir=$dump_norm_dir/$train_set/in_tacotron/ \
        data.train.out_dir=$dump_norm_dir/$train_set/out_tacotron/ \
        data.dev.utt_list=data/dev.list \
        data.dev.in_dir=$dump_norm_dir/$dev_set/in_tacotron/ \
        data.dev.out_dir=$dump_norm_dir/$dev_set/out_tacotron/ \
        train.out_dir=$expdir/${acoustic_model} \
        train.log_dir=tensorboard/${expname}_${acoustic_model} \
        train.max_train_steps=$tacotron_train_max_train_steps \
        data.batch_size=$tacotron_data_batch_size \
        cudnn.benchmark=$cudnn_benchmark cudnn.deterministic=$cudnn_deterministic \
        train.pretrained.checkpoint=$pretrained_acoustic_checkpoint
fi


if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    echo "stage 4: Training Parallel WaveGAN"
    if [ -z ${pretrained_vocoder_checkpoint} ]; then
        voc_expdir=$PWD/../../jsut/tacotron2_pwg/exp/jsut_sr${sample_rate}/${vocoder_model}
        pretrained_vocoder_checkpoint="$(ls -dt "$voc_expdir"/*.pkl | head -1 || true)"
        if [ ! -e $pretrained_vocoder_checkpoint ]; then
            echo "Please first train a PWG model for JSUT corpus!"
            echo "Expected model path: $pretrained_vocoder_checkpoint"
            exit 1
        fi
    fi
    xrun parallel-wavegan-train --config $parallel_wavegan_config \
        --train-dumpdir $dump_norm_dir/$train_set/out_tacotron \
        --dev-dumpdir $dump_norm_dir/$dev_set/out_tacotron/ \
        --outdir $expdir/$vocoder_model \
        --resume $pretrained_vocoder_checkpoint
fi

if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
    echo "stage 5: Synthesis waveforms by parallel_wavegan"
    if [ -z "${vocoder_eval_checkpoint}" ]; then
        vocoder_eval_checkpoint="$(ls -dt "${expdir}/${vocoder_model}"/*.pkl | head -1 || true)"
    fi
    outdir="${expdir}/$vocoder_model/wav/$(basename "${vocoder_eval_checkpoint}" .pkl)"
    for s in ${testsets[@]}; do
        xrun parallel-wavegan-decode --dumpdir $dump_norm_dir/$s/out_tacotron/ \
            --checkpoint $vocoder_eval_checkpoint \
            --outdir $outdir
    done
fi

if [ ${stage} -le 99 ] && [ ${stop_stage} -ge 99 ]; then
    echo "Pack models for TTS"
    dst_dir=tts_models/${expname}_${acoustic_model}_${vocoder_model}
    mkdir -p $dst_dir

    # global config
    cat > ${dst_dir}/config.yaml <<EOL
sample_rate: ${sample_rate}
acoustic_model: ${acoustic_model}
vocoder_model: ${vocoder_model}
EOL

    # Acoustic model
    python $COMMON_ROOT/clean_checkpoint_state.py $expdir/${acoustic_model}/$acoustic_eval_checkpoint \
        $dst_dir/acoustic_model.pth
    cp $expdir/${acoustic_model}/model.yaml $dst_dir/acoustic_model.yaml

    # parallel wavegan
    if [ -z "${vocoder_eval_checkpoint}" ]; then
        vocoder_eval_checkpoint="$(ls -dt "$expdir/$vocoder_model"/*.pkl | head -1 || true)"
    fi
    python $COMMON_ROOT/clean_checkpoint_state.py $vocoder_eval_checkpoint \
        $dst_dir/vocoder_model.pth
    cp $expdir/${vocoder_model}/config.yml $dst_dir/vocoder_model.yaml

    # speaker info
    for f in spks spk2id; do
	cp data/$f $dst_dir/
    done

    echo "All the files are ready for TTS!"
    echo "Please check the $dst_dir directory"
 fi
