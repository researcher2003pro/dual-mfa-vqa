require 'nn'
require 'rnn'
require 'cutorch'
require 'cunn'
require 'optim'
require 'hdf5'
require 'misc.myutils'
cjson = require('cjson');
require 'xlua'

-------------------------------------------------------------------------------
-- [1] Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('Test the Visual Question Answering model')
cmd:text()
cmd:text('Options')

-- Data input settings
cmd:option('-input_img_h5','../VQA/Features/img_features_res152_test-dev.h5','path to the h5file containing the image feature')
cmd:option('-input_ques_h5','data_train-val_test-dev_2k/vqa_data_prepro.h5','path to the h5file containing the preprocessed dataset')
cmd:option('-input_json','data_train-val_test-dev_2k/vqa_data_prepro.json','path to the json file containing additional info and vocab')
cmd:option('-fr_ms_h5', '../VQA/Features/faster-rcnn_features_19_test.h5', 'path to mscoco image faster-rcnn h5 file')
cmd:option('-model_path', 'model/mrn2k.t7', 'path to a model checkpoint to initialize model weights from. Empty = don\'t')
cmd:option('-out_path', 'result/', 'path to save output json file')
cmd:option('-out_prob', false, 'save prediction probability matrix as `model_name.t7`')
cmd:option('-type', 'test-dev2015', 'evaluation set')

-- Model parameter settings (shoud be the same with the training)
cmd:option('-backend', 'nn', 'nn|cudnn')
cmd:option('-batch_size', 200,'batch_size for each iterations')
cmd:option('-rnn_model', 'GRU', 'question embedding model')
cmd:option('-input_encoding_size', 620, 'he encoding size of each token in the vocabulary')
cmd:option('-rnn_size',2400,'size of the rnn in number of hidden nodes in each layer')
cmd:option('-common_embedding_size', 1200, 'size of the common embedding vector')
cmd:option('-num_output', 2000, 'number of output answers')
cmd:option('-glimpse', 2, '# of glimpses')

-- Overall attetion model settings
cmd:option('-MFA_model_name', 'MFA1g', 'MFA1 model name')
cmd:option('-MFA2_model_name', 'MFA2g', 'MFA2 model name')
cmd:option('-fusion_model_name', 'ADD', 'fusion model name')
cmd:option('-att_model_name', 'ATT7b', 'attention model name')
cmd:option('-output_model_name', 'dual-mfa', 'output model name') -- eg., dual-mfa

-- Misc
cmd:option('-backend', 'cudnn', 'nn|cudnn')
cmd:option('-gpuid', 0, 'which gpu to use. -1 = use CPU')
cmd:option('-seed', 1231, 'random number generator seed to use')
cmd:option('-nGPU', 1, 'how many gpu to use. 1 = use 1 GPU')

opt = cmd:parse(arg)
print(opt)

------------------------------------------------------------------------
-- [2] Setting the parameters
------------------------------------------------------------------------
torch.setdefaulttensortype('torch.FloatTensor') -- for CPU

require 'misc.RNNUtils'

if opt.gpuid >= 0 then
  require 'cutorch'
  require 'cunn'
  if opt.backend == 'cudnn' then require 'cudnn' end
  cutorch.setDevice(opt.gpuid + 1)
end

local output_model_name = opt.output_model_name
local model_path = opt.model_path
local batch_size = opt.batch_size
local embedding_size_q = opt.input_encoding_size
local rnn_size_q = opt.rnn_size
local common_embedding_size = opt.common_embedding_size
local noutput = opt.num_output
local glimpse = opt.glimpse

------------------------------------------------------------------------
-- [3] Loading Dataset
------------------------------------------------------------------------
-- DataLoader: loading input_json json file
print('DataLoader loading h5 file: ', opt.input_json)
local file = io.open(opt.input_json, 'r')
local text = file:read()
file:close()
json_file = cjson.decode(text)

-- DataLoader: loading input_ques h5 file
print('DataLoader loading h5 file: ', opt.input_ques_h5)
dataset = {}
local h5_file = hdf5.open(opt.input_ques_h5, 'r')
dataset['question'] = h5_file:read('/ques_test'):all()
dataset['lengths_q'] = h5_file:read('/ques_len_test'):all()
dataset['img_list'] = h5_file:read('/img_pos_test'):all()
dataset['ques_id'] = h5_file:read('/ques_id_test'):all()
dataset['MC_ans_test'] = h5_file:read('/MC_ans_test'):all()
h5_file:close()

-- DataLoader: loading image h5 files
print('DataLoader loading h5 file: ', opt.input_img_h5)
local h5_file = hdf5.open(opt.input_img_h5, 'r')
local h5_file_frms = hdf5.open(opt.fr_ms_h5, 'r') 
local test_list = {}
for i,imname in pairs(json_file['unique_img_test']) do
   table.insert(test_list, imname)
end
-- {"test2015/COCO_test2015_000000006350.jpg", "test2015/COCO_test2015_000000084152.jpg"}

local nhimage = 2048
dataset['question'] = right_align(dataset['question'],dataset['lengths_q'])

local count = 0
for i, w in pairs(json_file['ix_to_word']) do count = count + 1 end
local vocabulary_size_q = count

collectgarbage();

------------------------------------------------------------------------
-- [4] Design Parameters and Network Definitions
------------------------------------------------------------------------
lookup = nn.LookupTableMaskZero(vocabulary_size_q, embedding_size_q)

if opt.rnn_model == 'GRU' then
   -- Bayesian GRUs have right dropouts
   bgru = nn.GRU(embedding_size_q, rnn_size_q, false, .25, true)
   bgru:trimZero(1)
   -- encoder: RNN body
   encoder_net_q = nn.Sequential()
               :add(nn.Sequencer(bgru))
               :add(nn.SelectTable(-1))
end

-- embedding: word-embedding
embedding_net_q=nn.Sequential()
            :add(lookup)
            :add(nn.SplitTable(2))
collectgarbage()

----------------------------------
-- Dual-MFA
----------------------------------
-- MFA1
print('load MFA1 model:', opt.MFA_model_name)
require('netdef.MFA')
mfa_net1 = netdef[opt.MFA_model_name](rnn_size_q,nhimage,common_embedding_size,glimpse) -- 1200x2 --> 2000
mfa_net1:getParameters():uniform(-0.08, 0.08) 

-- MFA2
print('load MFA2 model:', opt.MFA2_model_name)
require('netdef.MFA')
mfa_net2 = netdef[opt.MFA2_model_name](rnn_size_q,4097,common_embedding_size,glimpse) -- 1200x2 --> 2000
mfa_net2:getParameters():uniform(-0.08, 0.08) 

-- FUS
require('netdef.FUS')
fusion_net = netdef[opt.fusion_model_name](common_embedding_size, noutput, glimpse) -- 1200x2 --> 2000

-- Oral attention model
require('netdef.ATT')
model = netdef[opt.att_model_name]()

-- Criterion
criterion = nn.CrossEntropyCriterion()

-- print(model)
collectgarbage()

----------------------------------
-- Optimization Setting
----------------------------------
if opt.gpuid >= 0 then
   print('shipped data function to cuda...')
   model = model:cuda()
   criterion = criterion:cuda()
   cudnn.fastest = true
   cudnn.benchmark = true
end

model:evaluate() -- setting to evaluation

w,dw = model:getParameters();
print('nParams=', w:size())

model_param = torch.load(model_path); -- loading the model
w:copy(model_param) -- using the precedding parameters


------------------------------------------------------------------------
-- [5] Grab Next Batch
------------------------------------------------------------------------
function dataset:next_batch_test(s,e)
   local batch_size = e-s+1;
   local qinds = torch.LongTensor(batch_size):fill(0);
   local iminds = torch.LongTensor(batch_size):fill(0);
   local fv_im = torch.Tensor(batch_size,2048,14,14);
   local fr_im = torch.Tensor(batch_size,19,4097):zero();

   for i = 1,batch_size do
      qinds[i] = s+i-1;
      iminds[i] = dataset['img_list'][qinds[i]];
      fv_im[i]:copy(h5_file:read(paths.basename(test_list[iminds[i]])):all())
      fr_im[i]:copy(h5_file_frms:read(paths.basename(test_list[iminds[i]])):all())
   end
   local fv_sorted_q = dataset['question']:index(1,qinds) 
   local qids = dataset['ques_id']:index(1,qinds);

   -- ship to gpu
   if opt.gpuid >= 0 then
      fv_sorted_q = fv_sorted_q:cuda() 
      fv_im = fv_im:cuda()
      fr_im = fr_im:cuda()
   end
  
   return fv_sorted_q, fv_im, fr_im, qids, batch_size;
end


------------------------------------------------------------------------
-- [6] Objective Function and Optimization
------------------------------------------------------------------------
function forward(s,e)
   local timer = torch.Timer();
   --grab a batch--
   local fv_sorted_q,fv_im,fr_im,qids,batch_size = dataset:next_batch_test(s,e);
   model:cuda()
   local scores = model:forward({fv_sorted_q, fv_im, fr_im,})
   return scores:double(), qids;
end


-----------------------------------------------------------------------
-- [7] Do Prediction
-----------------------------------------------------------------------
nqs = dataset['question']:size(1);
scores = torch.Tensor(nqs,noutput);
qids = torch.LongTensor(nqs);

for i = 1, nqs, batch_size do
   xlua.progress(i, nqs);if batch_size>nqs-i then xlua.progress(nqs, nqs) end
   r = math.min(i+batch_size-1,nqs);
   scores[{{i,r},{}}],qids[{{i,r}}] = forward(i,r);
end

if opt.out_prob then torch.save(output_model_name..'.t7', scores); return end

tmp, pred = torch.max(scores,2);


------------------------------------------------------------------------
-- [8] Write to json file
------------------------------------------------------------------------
paths.mkdir(opt.out_path)

-- Open-ended task
response = {};
for i = 1, nqs do
  table.insert(response,{question_id=qids[i],answer=json_file['ix_to_ans'][tostring(pred[{i,1}])]})
end
saveJson(opt.out_path .. 'vqa_OpenEnded_mscoco_'..opt.type..'_'..output_model_name..'_results.json',response);

-- Multi-choice task
mc_response = {};
for i = 1, nqs do
   local mc_prob = {}
   local mc_idx = dataset['MC_ans_test'][i]
   local tmp_idx = {}
   for j = 1, mc_idx:size()[1] do
      if mc_idx[j] ~= 0 then
         table.insert(mc_prob, scores[{i, mc_idx[j]}])
         table.insert(tmp_idx, mc_idx[j])
      end
   end
   local tmp, tmp2 = torch.max(torch.Tensor(mc_prob), 1);
   table.insert(mc_response, {question_id=qids[i], answer=json_file['ix_to_ans'][tostring(tmp_idx[tmp2[1]])]})
end
saveJson(opt.out_path .. 'vqa_MultipleChoice_mscoco_'..opt.type..'_'..output_model_name..'_results.json',mc_response);

print('Save Json DONE!')
h5_file:close()
h5_file_frms:close()
print('Close H5 File DONE!')
