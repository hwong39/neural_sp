#!/bin/bash

# Copyright 2019 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

echo ============================================================================
echo "                                  PTB                                     "
echo ============================================================================

stage=0
gpu=

### vocabulary
unit=word
vocab_size=10000

#########################
# LM configuration
#########################
# topology
lm_type=lstm
n_units=1024
n_projs=0
n_layers=2
emb_dim=1024
tie_embedding=true
residual=true
use_glu=true
# optimization
batch_size=20
bptt=30
optimizer=adam
learning_rate=1e-3
n_epochs=50
convert_to_sgd_epoch=50
print_step=100
decay_start_epoch=10
decay_rate=0.9
decay_patient_n_epochs=0
not_improved_patient_n_epochs=10
eval_start_epoch=1
# initialization
param_init=0.05
pretrained_model=
# regularization
clip_grad_norm=0.1
dropout_hidden=0.65
dropout_out=0.0
dropout_emb=0.2
weight_decay=1e-6

### path to save the model
model=/n/sd3/inaguma/result/ptb

### path to the model directory to resume training
resume=

### path to save preproecssed data
data=/n/sd3/inaguma/corpus/ptb

. ./cmd.sh
. ./path.sh
. utils/parse_options.sh

set -e
set -u
set -o pipefail

if [ -z ${gpu} ]; then
    echo "Error: set GPU number." 1>&2
    echo "Usage: ./run.sh --gpu 0" 1>&2
    exit 1
fi
n_gpus=$(echo ${gpu} | tr "," "\n" | wc -l)

train_set=train
dev_set=valid
test_set=test

if [ ${stage} -le 0 ] && [ ! -e ${data}/.done_stage_0 ]; then
    echo ============================================================================
    echo "                       Data Preparation (stage:0)                          "
    echo ============================================================================

    mkdir -p ${data}
    wget http://www.fit.vutbr.cz/~imikolov/rnnlm/simple-examples.tgz -P ${data}
    tar xf ${data}/simple-examples.tgz -C ${data}
    # NOTE: OOV words are already replaced with <unk>

    for x in ${train_set} ${dev_set} ${test_set}; do
        mkdir -p ${data}/${x}
        cat ${data}/simple-examples/data/ptb.${x}.txt | grep -v '^\s*$' | sed -e 's/^[ ]*//g' | awk '{print NR, $0}' > ${data}/${x}/text
        # NOTE: Skip empty line
    done

    touch ${data}/.done_stage_0 && echo "Finish data preparation (stage: 0)."
fi

dict=${data}/dict/${train_set}_${unit}${vocab_size}.txt; mkdir -p ${data}/dict
if [ ${stage} -le 2 ] && [ ! -e ${data}/.done_stage_2 ]; then
    echo ============================================================================
    echo "                      Dataset preparation (stage:2)                        "
    echo ============================================================================

    echo "Making a dictionary..."
    echo "<unk> 1" > ${dict}  # <unk> must be 1, 0 will be used for "blank" in CTC
    echo "<eos> 2" >> ${dict}  # <sos> and <eos> share the same index
    echo "<pad> 3" >> ${dict}
    offset=$(cat ${dict} | wc -l)
    text2dict.py ${data}/${train_set}/text --unit ${unit} --vocab_size ${vocab_size} | grep -v "<unk>" | \
        awk -v offset=${offset} '{print $0 " " NR+offset}' >> ${dict} || exit 1;
    echo "vocab size:" $(cat ${dict} | wc -l)

    echo "Making dataset tsv files for LM ..."
    mkdir -p ${data}/dataset
    for x in ${train_set} ${dev_set} ${test_set}; do
        make_dataset.sh --unit ${unit} ${data}/${x} ${dict} > ${data}/dataset/${x}_${unit}${vocab_size}.tsv || exit 1;
    done

    touch ${data}/.done_stage_2 && echo "Finish creating dataset for LM (stage: 2)."
fi

mkdir -p ${model}
if [ ${stage} -le 3 ]; then
    echo ============================================================================
    echo "                        LM Training stage (stage:3)                       "
    echo ============================================================================

    # NOTE: support only a single GPU for LM training
    CUDA_VISIBLE_DEVICES=${gpu} ${NEURALSP_ROOT}/neural_sp/bin/lm/train.py \
        --corpus ptb \
        --n_gpus 1 \
        --train_set ${data}/dataset/${train_set}_${unit}${vocab_size}.tsv \
        --dev_set ${data}/dataset/${dev_set}_${unit}${vocab_size}.tsv \
        --dict ${dict} \
        --model ${model}/lm \
        --unit ${unit} \
        --lm_type ${lm_type} \
        --n_units ${n_units} \
        --n_projs ${n_projs} \
        --n_layers ${n_layers} \
        --emb_dim ${emb_dim} \
        --tie_embedding ${tie_embedding} \
        --residual ${residual} \
        --use_glu ${use_glu} \
        --batch_size ${batch_size} \
        --bptt ${bptt} \
        --optimizer ${optimizer} \
        --learning_rate ${learning_rate} \
        --n_epochs ${n_epochs} \
        --convert_to_sgd_epoch ${convert_to_sgd_epoch} \
        --print_step ${print_step} \
        --decay_start_epoch ${decay_start_epoch} \
        --decay_rate ${decay_rate} \
        --decay_patient_n_epochs ${decay_patient_n_epochs} \
        --not_improved_patient_n_epochs ${not_improved_patient_n_epochs} \
        --eval_start_epoch ${eval_start_epoch} \
        --param_init ${param_init} \
        --pretrained_model ${pretrained_model} \
        --clip_grad_norm ${clip_grad_norm} \
        --dropout_hidden ${dropout_hidden} \
        --dropout_out ${dropout_out} \
        --dropout_emb ${dropout_emb} \
        --weight_decay ${weight_decay} \
        --resume ${resume} || exit 1;

    echo "Finish LM training (stage: 3)." && exit 1;
fi
