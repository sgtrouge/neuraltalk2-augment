# Neural-Talk-2 with augmented input data

In this modified version of Karpathy's work, I am trying to see whether random cropping of image during testing phase can improve the accuracy of the captioning. Feel free to modify with the code. More specifically, use the flag -image_augment and toy around with the code that use add_crop. 

Recent update provides add_crop with more power, as we can use PCA to produce RBG noise to the original image for extra augmentation. Also provided a small tweak to provide feature dropout.

If you can find any interesting sample, please let me know. 

# TODO
So far manual testing have shown some improvement in specific cases, but also decrease in others, mostly a trade-off between attention to detail vs overall relation between objects. Need to figure out a good weight scheme and cropping ratio do find this balance.
