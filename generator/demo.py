import argparse
import pickle
import torch
import pandas
from autoencoder import Autoencoder
from gan import Generator
from missingprocessor import Processor
import os
import errno
import json
import numpy as np
import pandas as pd
def make_sure_path_exists(path):
    try:
        os.makedirs(path)
    except OSError as exception:
        if exception.errno != errno.EEXIST:
            raise

def synthesize(decoder, generator, static_processor, dynamic_processor, params, n, batch_size=500):
    ae.decoder.eval()
    generator.eval()
    sta = []
    def _gen(n):
        with torch.no_grad():
            z = torch.randn(n, params['noise_dim']).to(device)
            hidden =generator(z)
            statics = ae.decoder.generate_statics(hidden)
            df_sta = static_processor.inverse_transform(statics.cpu().numpy())
            max_len = int(df_sta['seq_len'].max())
            dynamics, missing, times = ae.decoder.generate_dynamics(hidden, statics, max_len)
            dynamics = dynamics.cpu().numpy()
            missing = missing.cpu().numpy()
            times = times.cpu().numpy()

        sta.append(df_sta)
        res = []
        for i in range(n):
            length = int(df_sta['seq_len'].values[i])
            dyn = dynamic_processor.inverse_transform(dynamics[i,:length], missing[i,:length], times[i,:length])
            for x in ['Glascow coma scale total']:
                dyn[x] = np.array([y if y!=y else int(round(y)) for y in dyn[x].values.astype('float')], dtype=object)
            res.append(dyn)

        return res

    data = []
    tt = n // batch_size
    for i in range(tt):
        data.extend(_gen(batch_size))
    res = n - tt * batch_size
    if res>0:
        data.extend(_gen(res))
    sta = pd.concat(sta, ignore_index=True)
    sta.drop(columns=["seq_len"], inplace=True)
    print(data[0])
    return sta, data

if __name__=="__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--pretrained", default='./example', dest="pretrained", help="pretrained dir to use")
    parser.add_argument("--output", default="./gen", dest="output", help="output dir to use")
    options = parser.parse_args()
    
    params = json.load(open(options.pretrained+"/params.json","r"))
    processors = pickle.load(open(options.pretrained+"/type.pkl", "rb"))
    ae = Autoencoder(processors, params["hidden_dim"], params["embed_dim"], params["layers"], dropout=params["dropout"])
    generator = Generator(params["noise_dim"], params["hidden_dim"], params["layers"])
    
    device= torch.device("cpu")
    ae.load_state_dict(torch.load(options.pretrained+"/ae.dat", map_location=device))
    generator.load_state_dict(torch.load(options.pretrained+"/generator.dat", map_location=device))
    
    #ae = ae.cuda()
    #generator = generator.cuda()
    
    sta, dyn = synthesize(ae.decoder, generator, processors[0], processors[1], params, params["n"])
    make_sure_path_exists(options.output)
    print(sta["y_true"].value_counts())
    lis = []
    for i, res in enumerate(dyn):
        lis.append("{}.csv".format(i))
        res.to_csv("{}/{}.csv".format(options.output,i), sep=',', index=False)
    sta["stay"] = np.array(lis)
    sta=sta[['stay','y_true']]
    sta.to_csv("{}/listfile.csv".format(options.output), sep=',', index=False)
