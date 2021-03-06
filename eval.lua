require 'torch'
require 'nn'
require 'nngraph'
require 'unsup'
-- exotics
require 'loadcaffe'
-- local imports
local utils = require 'misc.utils'
require 'misc.DataLoader'
require 'misc.DataLoaderRaw'
require 'misc.LanguageModel'
local net_utils = require 'misc.net_utils'

-------------------------------------------------------------------------------
-- Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train an Image Captioning model')
cmd:text()
cmd:text('Options')

-- Input paths
cmd:option('-model','','path to model to evaluate')
-- Basic options
cmd:option('-batch_size', 1, 'if > 0 then overrule, otherwise load from checkpoint.')
cmd:option('-crop_midsize', 200, 'size of crop augment')
cmd:option('-crop_smallsize', 150, 'size of crop augment')

cmd:option('-iterx', -1, 'size of crop augment')
cmd:option('-itery', -1, 'size of crop augment')
cmd:option('-ori_weight', 1, 'weight for original image')
cmd:option('-mid_weight', 1, 'weight for original image')
cmd:option('-small_weight', 1, 'weight for original image')

cmd:option('-num_images', 100, 'how many images to use when periodically evaluating the loss? (-1 = all)')
cmd:option('-language_eval', 0, 'Evaluate language as well (1 = yes, 0 = no)? BLEU/CIDEr/METEOR/ROUGE_L? requires coco-caption code from Github.')
cmd:option('-dump_images', 0, 'Dump images into vis/imgs folder for vis? (1=yes,0=no)')
cmd:option('-dump_json', 0, 'Dump json with predictions into vis folder? (1=yes,0=no)')
cmd:option('-dump_path', 0, 'Write image paths along with predictions into vis json? (1=yes,0=no)')
-- Sampling options
cmd:option('-sample_max', 1, '1 = sample argmax words. 0 = sample from distributions.')
cmd:option('-beam_size', 2, 'used when sample_max = 1, indicates number of beams in beam search. Usually 2 or 3 works well. More is not better. Set this to 1 for faster runtime but a bit worse performance.')
cmd:option('-temperature', 1.0, 'temperature when sampling from distributions (i.e. when sample_max = 0). Lower = "safer" predictions.')
-- For evaluation on a folder of images:
cmd:option('-image_folder', '', 'If this is nonempty then will predict on the images in this folder path')
cmd:option('-image_augment', 0, 'If this is 1 then will eval images by augmentation')
cmd:option('-aug_size', 0, 'Number of augmentation per image (cropping atm)')
cmd:option('-image_root', '', 'In case the image paths have to be preprended with a root path to an image folder')
-- For evaluation on MSCOCO images from some split:
cmd:option('-input_h5','','path to the h5file containing the preprocessed dataset. empty = fetch from model checkpoint.')
cmd:option('-input_json','','path to the json file containing additional info and vocab. empty = fetch from model checkpoint.')
cmd:option('-split', 'test', 'if running on MSCOCO images, which split to use: val|test|train')
cmd:option('-coco_json', '', 'if nonempty then use this file in DataLoaderRaw (see docs there). Used only in MSCOCO test evaluation, where we have a specific json file of only test set images.')
-- misc
cmd:option('-backend', 'cudnn', 'nn|cudnn')
cmd:option('-id', 'evalscript', 'an id identifying this run/job. used only if language_eval = 1 for appending to intermediate files')
cmd:option('-seed', 123, 'random number generator seed to use')
cmd:option('-gpuid', 0, 'which gpu to use. -1 = use CPU')
cmd:text()

-------------------------------------------------------------------------------
-- Basic Torch initializations
-------------------------------------------------------------------------------
local opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
torch.setdefaulttensortype('torch.FloatTensor') -- for CPU

if opt.gpuid >= 0 then
  require 'cutorch'
  require 'cunn'
  if opt.backend == 'cudnn' then require 'cudnn' end
  cutorch.manualSeed(opt.seed)
  cutorch.setDevice(opt.gpuid + 1) -- note +1 because lua is 1-indexed
end

-------------------------------------------------------------------------------
-- Load the model checkpoint to evaluate
-------------------------------------------------------------------------------
assert(string.len(opt.model) > 0, 'must provide a model')
local checkpoint = torch.load(opt.model)
-- override and collect parameters
if string.len(opt.input_h5) == 0 then opt.input_h5 = checkpoint.opt.input_h5 end
if string.len(opt.input_json) == 0 then opt.input_json = checkpoint.opt.input_json end
if opt.batch_size == 0 then opt.batch_size = checkpoint.opt.batch_size end
local fetch = {'rnn_size', 'input_encoding_size', 'drop_prob_lm', 'cnn_proto', 'cnn_model', 'seq_per_img'}
for k,v in pairs(fetch) do 
  opt[v] = checkpoint.opt[v] -- copy over options from model
end
local vocab = checkpoint.vocab -- ix -> word mapping

-------------------------------------------------------------------------------
-- Create the Data Loader instance
-------------------------------------------------------------------------------
local loader
if string.len(opt.image_folder) == 0 then
  loader = DataLoader{h5_file = opt.input_h5, json_file = opt.input_json}
else
  loader = DataLoaderRaw{folder_path = opt.image_folder, coco_json = opt.coco_json}
end

-------------------------------------------------------------------------------
-- Load the networks from model checkpoint
-------------------------------------------------------------------------------
local protos = checkpoint.protos
protos.expander = nn.FeatExpander(opt.seq_per_img)
protos.crit = nn.LanguageModelCriterion()
protos.lm:createClones() -- reconstruct clones inside the language model
if opt.gpuid >= 0 then for k,v in pairs(protos) do v:cuda() end end

--------- 
local function findPCA(ori_images)
  local agg_matrix = torch.reshape(ori_images[1][{{},{1}, {1}}], 1, 3)
  local max_m = 0
  for i = 1, ori_images:size(1) do
    for rx = 1, 224 do
      for ry = 1, 224 do
        if i*rx*ry > 1 then
          agg_matrix = torch.cat(agg_matrix, torch.reshape(ori_images[i][{{},{rx}, {ry}}], 1, 3) ,1)
        end
      end
    end
  end
  local ce, cv = unsup.pcacov(agg_matrix[{{},{}}]:double())
  return ce, cv
end

local function RGBnoise(float_images, eigenvalues, eigenvectors)
  local num_images = float_images:size(1)
  local res_images = torch.DoubleTensor(num_images, 3, 224, 224)
  for i = 1, num_images do
    local tmp = torch.DoubleTensor(3,1)
    tmp[1] = torch.normal(0, 0.1)
    tmp[2] = torch.normal(0, 0.1)
    tmp[3] = torch.normal(0, 0.1)
    for channel = 1, 3 do
      for rx = 1, 224 do
        for ry = 1, 224 do
          res_images[i][channel][rx][ry] = float_images[i][channel][rx][ry] + tmp[channel][1]
        end
      end
    end
  end
  return res_images:float()
end
-------------------------------------------------------------------------------
local function add_crop(sum_array, ori_images, iter, weight, crop_size, drop_out_chance, noise_on, ce, cv, mean_filter_on, center, xoff, yoff)
  local crop_images = torch.ByteTensor(ori_images:size(1), 3, 224, 224)
  for i = 1,iter do
    -- specifiy scale of crop
    local cnn_input_size = 224 
    -- choose coordinate to crop
    local h,w = ori_images:size(3), ori_images:size(4)
    if (xoff == nil or xoff < 0) then
      if center == 1 then
        xoff, yoff = math.ceil((w-cnn_input_size)/2), math.ceil((h-cnn_input_size)/2)
      else
        xoff, yoff = torch.random(w-crop_size), torch.random(h-crop_size)
      end
    end
    for i=1,opt.batch_size do
      crop_images[i] = image.scale(ori_images[i][{{}, {yoff,yoff+crop_size-1}, {xoff,xoff+crop_size-1}}], cnn_input_size, cnn_input_size)
    end

    -- convert/extra preprocess before feeding
    if on_gpu then crop_images = crop_images:cuda() else crop_images = crop_images:float() end

    -- lazily instantiate vgg_mean
    if not net_utils.vgg_mean then
      net_utils.vgg_mean = torch.FloatTensor{123.68, 116.779, 103.939}:view(1,3,1,1) -- in RGB order
    end
    net_utils.vgg_mean = net_utils.vgg_mean:typeAs(crop_images) -- a noop if the types match
    -- subtract vgg mean
    crop_images:add(-1, net_utils.vgg_mean:expandAs(crop_images))
    if noise_on == true then   
      crop_images = RGBnoise(crop_images, ce, cv)
    end
    -- adding weight to sum
    local crop_feats = protos.cnn:forward(crop_images)
    local feat_size = crop_feats:size(2)
    for i=1,opt.batch_size do
      local max_feat = 0
      local sum_feat = 0
      for j=1,feat_size do
        max_feat = math.max(max_feat, crop_feats[i][j])
        sum_feat = sum_feat + crop_feats[i][j]
      end
        mean_feat = sum_feat/feat_size
      for j=1,feat_size do
        local p = 1
        --normalize by dropout rate
        if (drop_out_chance >= 0) then
          p = math.min(1, crop_feats[i][j]/mean_feat*drop_out_chance)
          p = torch.bernoulli(p)
        end

        --mean filter
        if (mean_filter_on == true) then
          if (crop_feats[i][j] < sum_feat/feat_size) then
            p = 0
          end
        end
        sum_array[i][j] = sum_array[i][j] + crop_feats[i][j]*weight*p
      end
    end        
  end
end


-------------------------------------------------------------------------------
-- Evaluation fun(ction)
-------------------------------------------------------------------------------
local function eval_split(split, evalopt)
  local verbose = utils.getopt(evalopt, 'verbose', true)
  local num_images = utils.getopt(evalopt, 'num_images', true)

  protos.cnn:evaluate()
  protos.lm:evaluate()
  loader:resetIterator(split) -- rewind iteator back to first datapoint in the split
  local n = 0
  local loss_sum = 0
  local loss_evals = 0
  local predictions = {}
  while true do
    -- fetch a batch of data
    local data = loader:getBatch{batch_size = opt.batch_size, split = split, seq_per_img = opt.seq_per_img}
    local ori_images = torch.ByteTensor(opt.batch_size, 3, 256, 256)
    ori_images = data.images
    local ce, cv = findPCA(ori_images)
    data.images = net_utils.prepro(data.images, false, opt.gpuid >= 0) -- preprocess in place, and don't augment   

    n = n + data.images:size(1)

    -- forward the model to get loss
    local feats = protos.cnn:forward(data.images)
    -- evaluate loss if we have the labels
    local loss = 0
    if data.labels then
      local expanded_feats = protos.expander:forward(feats)
      local logprobs = protos.lm:forward{expanded_feats, data.labels}
      loss = protos.crit:forward(logprobs, data.labels)
      loss_sum = loss_sum + loss
      loss_evals = loss_evals + 1
    end

    -- forward the model to also get generated samples for each image
    local sample_opts = { sample_max = opt.sample_max, beam_size = opt.beam_size, temperature = opt.temperature }
    local seq = protos.lm:sample(feats, sample_opts)
    local sents = net_utils.decode_sequence(vocab, seq)


    -- if augmentation flag is on then do so
    local avg_feats = feats -- technically still pointing to feats
    if opt.image_augment == 1 then
      local sum_array = {}
      -- init array
      for i =1,opt.batch_size do
        sum_array[i] = {}
        for j = 1,feats:size(2) do
          sum_array[i][j] = 0
        end
      end

      -- model 
      -- load the feats from original image
      -- instead of random, let's do stride crop
      add_crop(sum_array, ori_images, 1, opt.ori_weight, 224,-1,false, nil, nil, false,1)
      
      local tmpx = opt.iterx/math.abs(opt.iterx)
      local numcrops = opt.iterx*opt.itery/2
      for ix =1, math.abs(opt.iterx) do
        local tmpy = opt.itery/math.abs(opt.itery)
        for iy =1, math.abs(opt.itery/2) do
          add_crop(sum_array, ori_images,1, (opt.mid_weight)/numcrops, opt.crop_midsize,-1,false, nil, nil, false,0, tmpx, tmpy)
          tmpy = tmpy + torch.floor((256-opt.crop_midsize)/opt.itery)*2
        end
        tmpx = tmpx + torch.floor((256-opt.crop_midsize)/opt.iterx)
      end

      local tmpx = opt.iterx/math.abs(opt.iterx)
      for ix =1, math.abs(opt.iterx) do
        local tmpy = opt.itery/math.abs(opt.itery)
        for iy =1, math.abs(opt.itery/2) do
          add_crop(sum_array, ori_images,1, (opt.small_weight)/numcrops, opt.crop_smallsize,-1,false, nil, nil, false,0, tmpx, tmpy)
          tmpy = tmpy + torch.floor((256-opt.crop_smallsize)/opt.itery)*2
        end
        tmpx = tmpx + torch.floor((256-opt.crop_smallsize)/opt.iterx)
      end

      for i =1,opt.batch_size do
        for j = 1,avg_feats:size(2) do
          avg_feats[i][j] = sum_array[i][j]
        end
      end
    end
    
    local avg_seq = protos.lm:sample(avg_feats, sample_opts)
    local avg_sents = net_utils.decode_sequence(vocab, avg_seq)

    for k=1,#sents do
      local entry = {image_id = data.infos[k].id, caption = avg_sents[k], base_caption = sents[k]}
      if opt.dump_path == 1 then
        entry.file_name = data.infos[k].file_path
      end
      table.insert(predictions, entry)
      if opt.dump_images == 1 then
        -- dump the raw image to vis/ folder
        local cmd = 'cp "' .. path.join(opt.image_root, data.infos[k].file_path) .. '" vis/imgs/img' .. #predictions .. '.jpg' -- bit gross
        print(cmd)
        os.execute(cmd) -- dont think there is cleaner way in Lua
      end
      if verbose then
        print(string.format('image %s: \nour caption: %s\nbase caption: %s\n', data.infos[k].file_path, entry.caption, entry.base_caption))
      end
    end

    -- if we wrapped around the split or used up val imgs budget then bail
    local ix0 = data.bounds.it_pos_now
    local ix1 = math.min(data.bounds.it_max, num_images)
    if verbose then
      print(string.format('evaluating performance... %d/%d (%f)', ix0-1, ix1, loss))
    end

    if data.bounds.wrapped then break end -- the split ran out of data, lets break out
    if num_images >= 0 and n >= num_images then break end -- we've used enough images
  end

  local lang_stats
  if opt.language_eval == 1 then
    lang_stats = net_utils.language_eval(predictions, opt.id)
  end

  return loss_sum/loss_evals, predictions, lang_stats
end

local loss, split_predictions, lang_stats = eval_split(opt.split, {num_images = opt.num_images})
-- print('loss: ', loss)
if lang_stats then
  print(lang_stats)
end

if opt.dump_json == 1 then
  -- dump the json
  utils.write_json('vis/vis.json', split_predictions)
end
