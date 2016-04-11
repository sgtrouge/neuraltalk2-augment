# Neural-Talk-2 with augmented input data

In this modified version of Karpathy's work, I am trying to see whether random cropping of image during testing phase can improve the accuracy of the captioning. Feel free to modify with the code. More specifically, use the flag -image_augment and toy around with the code that use add_crop. If you can find any interesting sample, please let me know. 

# TODO
Find a good weighting scheme for cropping. I am trying to simulate how human mind work when they see an image, which region will they look at and how does the semantic information from that region affect the thinking process. 

option: 
figure out the output scheme of VGG net, then reweight the "counting" feature aptly (if we crop large image, then "number" informtation from it should weight larger than smaller image feature)
